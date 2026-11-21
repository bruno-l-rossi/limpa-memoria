part of 'main.dart';

// Rodada 19 (F4): ponte entre o motor da tela e o motor nativo (Kotlin), que
// sobe com o app fechado. Ligado em Ajustes > Em teste > "Subir com o app
// fechado". Desligado, nada aqui roda e o motor antigo segue igual.
//
// Fluxo: _alimentar entrega TODA a fila de uma vez ao motor nativo (fila.json)
// e liga ele; _importarNativo lê o que o motor concluiu (resultados.jsonl) e
// passa pelo mesmo _confirmarEnvio do motor antigo (contagem, store,
// duplicatas, celebração). Banner, conclusão e apagar continuam iguais.

extension _MotorNativoHome on _HomePageState {
  /// Motor nativo valendo nesta sessão do app?
  bool get _usaNativo => _motorFechado && !_nativoRecusado && _arqMotor != null;

  Future<void> _alimentarNativo() async {
    final arq = _arqMotor;
    final conta = _conta;
    if (arq == null || conta == null) return;
    // O Android só aceita ligar o trabalho longo com o app na tela.
    if (!_emPrimeiroPlano) return;
    final novos = <ItemBackup>[];
    final semCaminho = <ItemBackup>[];
    while (_pendentes.isNotEmpty) {
      final item = _tirarDaFila()!;
      if (item.dup.isNotEmpty ||
          _enviadosIds.contains(item.id) ||
          _noNativo.containsKey(item.id) ||
          !_emFila.contains(item.id)) {
        continue;
      }
      if (item.path.isEmpty) {
        semCaminho.add(item);
        continue;
      }
      novos.add(item);
    }
    for (final it in semCaminho) {
      // O motor nativo lê o arquivo pelo caminho; sem caminho, não tem como.
      _falhos[it.id] = it;
      _motivoFalha[it.id] =
          'O Android não deu o caminho deste arquivo. Desligue "Subir com o app fechado" em Ajustes pra ele subir pelo motor normal.';
    }
    if (novos.isEmpty) {
      if (semCaminho.isNotEmpty) _mudou();
      return;
    }

    if (!_nativoAutorizado) {
      final ok = await Nativo.motorAutorizar(conta.email);
      if (!ok) {
        _devolverNaFrente(novos);
        _recusarNativo('O Google não liberou o acesso pro motor do app fechado');
        return;
      }
      _nativoAutorizado = true;
    }

    await BackupService.garantirSubpastas(_gsi, novos.map((e) => e.pasta));
    final entregues = <ItemNativo>[];
    final semPasta = <ItemBackup>[];
    for (final it in novos) {
      final pai = BackupService.idSubpasta(it.pasta);
      if (pai == null) {
        semPasta.add(it);
      } else {
        entregues.add(ItemNativo(it, pai));
      }
    }
    if (semPasta.isNotEmpty) {
      // Não conseguiu achar/criar a pasta no Drive (rede?): tenta depois.
      _devolverNaFrente(semPasta);
      _esperarRede();
    }
    if (entregues.isEmpty) return;

    for (final e in entregues) {
      _noNativo[e.item.id] = e;
    }
    await arq.escreverFila(_noNativo.values);
    final bytes = _noNativo.values.fold<int>(0, (s, e) => s + e.item.bytes);
    final ok = await Nativo.motorIniciar(
        email: conta.email, soWifi: _soWifi, bytes: bytes);
    if (!ok) {
      for (final e in entregues) {
        _noNativo.remove(e.item.id);
      }
      await arq.escreverFila(_noNativo.values);
      _devolverNaFrente([for (final e in entregues) e.item]);
      _recusarNativo('O Android não deixou ligar o motor do app fechado');
      return;
    }
    _semVidaDesde = null;
    _ev('Motor do app fechado: +${entregues.length} arquivos (${_milhar(_noNativo.length)} com ele, ${_fmt(bytes)})');
    _mudou();
    _agendarRefresh();
  }

  /// Não deu pra usar o motor nativo: segue pelo antigo nesta sessão do app.
  void _recusarNativo(String motivo) {
    _nativoRecusado = true;
    _ev('$motivo: seguindo pelo motor normal');
    _avisar('$motivo. Seguindo pelo motor normal, com o app aberto.');
    _tick();
  }

  /// Lê o que o motor nativo concluiu desde a última leitura e confere o
  /// estado dele. Barato: só lê o que é novo no arquivo.
  Future<void> _importarNativo() async {
    final arq = _arqMotor;
    if (arq == null || _importandoNativo) return;
    _importandoNativo = true;
    try {
      if (!_offsetNativoLido) {
        _offsetNativo =
            int.tryParse(await _store.texto(UploadStore.kOffsetNativo) ?? '') ??
                0;
        _offsetNativoLido = true;
      }
      final (res, off) = await arq.lerResultados(_offsetNativo);
      for (final r in res) {
        final entregue = _noNativo.remove(r.id);
        if (r.ok) {
          await _confirmarEnvio(r.id, r.fileId, r.bytes,
              verificado: r.verificado);
          continue;
        }
        if (_enviadosIds.contains(r.id) || !_emFila.contains(r.id)) continue;
        final item = entregue?.item ?? _itemDoJob[r.id];
        if (item == null) continue;
        if (r.driveCheio) {
          _porNaFila(item, frente: true);
          await _pausarPorDriveCheio();
          continue;
        }
        final t = (_tentativas[r.id] ?? 0) + 1;
        _tentativas[r.id] = t;
        if (!r.definitivo && t <= 3 && !_pausado) {
          _porNaFila(item);
        } else {
          _falhos[r.id] = item;
          _telemetria.falhasDefinitivas++;
          _motivoFalha[r.id] = mensagemAmigavel(r.erro);
          _erroBg = r.erro;
          _ev('Falhou de vez (motor do app fechado): "${item.titulo}" (${item.pasta}) · ${r.erro}');
        }
      }
      if (off != _offsetNativo) {
        _offsetNativo = off;
        await _store.setTexto(UploadStore.kOffsetNativo, '$off');
      }

      final est = await arq.lerEstado();
      _estadoNativo = est;
      if (est != null && est.precisaLogin) _nativoAutorizado = false;
      final agora = DateTime.now();
      final vivo = est?.vivo(agora) ?? false;
      // Motor parado com arquivo entregue (kill, login, o sistema parou):
      // depois de 30 s, devolve pra fila; o próximo alimentar entrega de novo.
      if (!vivo && _noNativo.isNotEmpty && res.isEmpty) {
        _semVidaDesde ??= agora;
        if (agora.difference(_semVidaDesde!) > const Duration(seconds: 30)) {
          final volta = [for (final e in _noNativo.values) e.item];
          _noNativo.clear();
          _semVidaDesde = null;
          if (!_pausado) _devolverNaFrente(volta);
          _ev('Motor do app fechado parado com ${volta.length} entregues${est?.precisaLogin == true ? ' (precisa confirmar a conta)' : ''}: voltam pra fila');
          _mudou();
        }
      } else {
        _semVidaDesde = null;
      }
      if (res.isNotEmpty) {
        _mudou();
        _agendarRefresh();
      }
    } catch (e) {
      falhaEngolida('importar motor do app fechado', e);
    } finally {
      _importandoNativo = false;
    }
  }

  /// Para o motor nativo e esvazia a fila dele. O que já subiu fica; o que
  /// faltava continua no job (Retomar remonta).
  Future<void> _pararNativo() async {
    if (_arqMotor == null) return;
    if (_noNativo.isEmpty && !_motorFechado) return;
    _noNativo.clear();
    try {
      await _arqMotor!.escreverFila(const []);
    } catch (e) {
      falhaEngolida('esvaziar fila do motor', e);
    }
    await Nativo.motorParar();
    // O que concluiu no instante do Parar ainda entra.
    await _importarNativo();
  }
}
