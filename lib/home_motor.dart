part of 'main.dart';

// Rodada 18: saiu do main.dart (achado A-32).
// Motor do backup: fila, janela deslizante, reconciliação com o banco da
// biblioteca, conclusão, falhas, retomada e estimativa.

extension _MotorBackup on _HomePageState {
  /// MD5 de vários arquivos, 2 por vez (o pool nativo tem 2 threads), com
  /// diálogo de progresso quando são muitos. Devolve id -> MD5 dos que deu
  /// pra calcular, ou null se o usuário cancelou.
  Future<Map<String, String>?> _md5DeVarios(List<ItemBackup> itens,
      {required String titulo}) async {
    final res = <String, String>{};
    final faltam = <ItemBackup>[];
    for (final it in itens) {
      final c = _md5Cache[it.id];
      if (c != null) {
        res[it.id] = c;
      } else if (it.path.isNotEmpty) {
        faltam.add(it);
      }
    }
    if (faltam.isEmpty) return res;
    final progresso = ValueNotifier<double>(0);
    var cancelado = false;
    var dialogoAberto = false;
    NavigatorState? nav;
    // Só mostra diálogo se vai demorar (muitos arquivos ou muitos bytes).
    final totalBytes = faltam.fold<int>(0, (s, i) => s + i.bytes);
    if (mounted && (faltam.length > 20 || totalBytes > 200 * 1024 * 1024)) {
      nav = Navigator.of(context, rootNavigator: true);
      dialogoAberto = true;
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (ctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text(titulo),
            content: ValueListenableBuilder<double>(
              valueListenable: progresso,
              builder: (_, v, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: v),
                  const SizedBox(height: 8),
                  Text('${(v * 100).round()}%',
                      style: TextStyle(color: _inkMuted)),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () {
                    cancelado = true;
                    Navigator.pop(ctx);
                  },
                  child: const Text('Cancelar')),
            ],
          ),
        ),
      ).then((_) => dialogoAberto = false));
    }
    var i = 0, feitos = 0;
    Future<void> trabalhador() async {
      while (!cancelado && i < faltam.length) {
        final it = faltam[i++];
        final m = await Nativo.md5(it.path);
        if (m != null) {
          _md5Cache[it.id] = m;
          res[it.id] = m;
        }
        feitos++;
        progresso.value = feitos / faltam.length;
      }
    }

    await Future.wait([trabalhador(), trabalhador()]);
    if (dialogoAberto && !cancelado) nav?.pop();
    progresso.dispose();
    if (cancelado) return null;
    _ev('MD5 de ${faltam.length} arquivos (${_fmt(totalBytes)})');
    return res;
  }
  void _calcStats() {
    if (_statsRev == _rev) return;
    var feitos = 0, bt = 0, bf = 0, peq = 0;
    for (final id in _emFila) {
      final b = _bytesPorId[id] ?? 0;
      bt += b;
      if (_enviadosIds.contains(id)) {
        feitos++;
        bf += b;
      } else if (b > 0 && b < _pequeno) {
        peq++;
      }
    }
    _cPequenosRestantes = peq;
    _cFeitos = feitos;
    _cBytesTotal = bt;
    _cBytesFeitos = bf;
    _statsRev = _rev;
  }
  int get _bgTotal => _emFila.length;
  int get _bgFeitos {
    _calcStats();
    return _cFeitos;
  }
  /// Ainda tem trabalho no motor (fila, preparo, upload ou conferência).
  bool get _trabalhando =>
      _pendentes.isNotEmpty ||
      _emAndamento.isNotEmpty ||
      _preparando.isNotEmpty ||
      _processando.isNotEmpty ||
      _emRetomavel.isNotEmpty ||
      _alimentando;
  /// A sessão parou de andar com arquivos que não subiram (falharam de vez).
  bool get _fimComFalhas =>
      _semeado &&
      _falhos.isNotEmpty &&
      _emFila.isNotEmpty &&
      !_pausado &&
      !_trabalhando &&
      _bgFeitos < _bgTotal;
  /// Bytes já seguros no Drive E ainda presentes no celular (o que dá pra
  /// liberar).
  int get _bytesSeguros {
    if (_seguroRev != _rev) {
      _seguroCache = _items
          .where((m) => _enviadosIds.contains(m.id))
          .fold(0, (s, m) => s + m.bytes);
      _seguroRev = _rev;
    }
    return _seguroCache;
  }
  Map<String, int> get _subiuPorPastaMapa {
    if (_subiuPorPastaRev != _rev) {
      final m = <String, int>{};
      for (final it in _items) {
        if (_enviadosIds.contains(it.id)) m[it.pasta] = (m[it.pasta] ?? 0) + 1;
      }
      _subiuPorPasta = m;
      _subiuPorPastaRev = _rev;
    }
    return _subiuPorPasta;
  }
  void _porNaFila(ItemBackup item, {bool frente = false}) {
    if (item.id.isEmpty || _naFila.contains(item.id)) return;
    _naFila.add(item.id);
    _fimRegistrado = false; // voltou trabalho: a sessão não acabou
    if (frente) {
      _pendentes.addFirst(item);
    } else {
      _pendentes.addLast(item);
    }
  }
  /// Devolve itens pra frente da fila mantendo a ordem deles.
  void _devolverNaFrente(List<ItemBackup> itens) {
    for (final it in itens.reversed) {
      _porNaFila(it, frente: true);
    }
  }
  ItemBackup? _tirarDaFila() {
    if (_pendentes.isEmpty) return null;
    final it = _pendentes.removeFirst();
    _naFila.remove(it.id);
    return it;
  }
  void _limparFila() {
    _pendentes.clear();
    _naFila.clear();
  }
  ItemBackup _itemPara(String id, Task? task) {
    final doJob = _itemDoJob[id];
    if (doJob != null) return doJob.dup.isEmpty ? doJob : doJob.comDup('');
    final meta = task != null ? MetaTarefa.decodificar(task.metaData) : null;
    return ItemBackup(
      id,
      (meta?.titulo.isNotEmpty ?? false)
          ? meta!.titulo
          : (task?.filename ?? 'sem nome'),
      meta?.pasta ?? 'Outros',
      bytes: meta?.bytes ?? (_bytesPorId[id] ?? 0),
    );
  }
  Future<void> _tick() async {
    await _reconciliar();
    await _alimentar();
  }
  Future<void> _reconciliar() async {
    if (_reconciliando) {
      _reconciliarDeNovo = true;
      return;
    }
    _reconciliando = true;
    try {
      do {
        _reconciliarDeNovo = false;
        await _reconciliarUmaVez();
      } while (_reconciliarDeNovo);
    } finally {
      _reconciliando = false;
    }
  }
  Future<void> _reconciliarUmaVez() async {
    // Sem conta (boot offline, token perdido): tenta login silencioso de
    // tempos em tempos e retoma sozinho quando voltar.
    if (_conta == null) {
      // Só insiste no login se tem backup pra continuar (sem job, nada de
      // rede a cada 2 min à toa).
      if (_emFila.isEmpty) return;
      await _tentarLoginSilencioso();
      if (_conta == null) return;
    }
    if (!_semeado) await _tentarRetomar();
    if (_emFila.isEmpty) return;
    try {
      final ativos = (await BackupService.idsAtivos())
          .where((id) => !_enviadosIds.contains(id))
          .toSet();

      // 1. Quem saiu da janela: concluiu? (o evento ao vivo pode ter escapado)
      for (final id in _emAndamento.difference(ativos)) {
        if (_processando.contains(id) || _enviadosIds.contains(id)) continue;
        final st = await BackupService.statusDe(id);
        if (st == TaskStatus.complete && !_processando.contains(id)) {
          await _confirmarEnvio(id, null, null);
        }
      }
      _emAndamento
        ..clear()
        ..addAll(ativos);

      // 2. Órfãos: itens da sessão que não estão em lugar nenhum (nem
      // enviados, nem na fila, nem no motor, nem falhos). Acontece quando um
      // evento de falha se perde. Antes ficavam esquecidos e a sessão nunca
      // fechava ("subindo agora 0, na fila 0" pra sempre).
      final agora = DateTime.now();
      if (!_pausado &&
          agora.difference(_ultimaVarredura) > const Duration(seconds: 60)) {
        _ultimaVarredura = agora;
        await _varrerOrfaos(agora);
      }

      // 3. Banco da biblioteca: apaga registros já reconciliados há 20s+
      // (dá tempo da gravação assíncrona da própria biblioteca terminar;
      // apagar na hora fazia o registro voltar).
      final velhos = _paraLimpar.entries
          .where((e) => agora.difference(e.value).inSeconds >= 20)
          .map((e) => e.key)
          .toList();
      if (velhos.isNotEmpty) {
        await BackupService.limparRegistros(velhos);
        for (final id in velhos) {
          _paraLimpar.remove(id);
        }
      }

      // 4. Itens que sumiram da galeria saem do job (uma gravação por tick).
      if (_sumidos.isNotEmpty) {
        final lote = Set<String>.of(_sumidos);
        _sumidos.clear();
        await _store.removerDoJob(lote);
      }

      _verificarFim();
      _notificarProgresso();
      _agendarRefresh();
    } catch (_) {
      // silencioso: tenta de novo no próximo tick
    }
  }
  Future<void> _varrerOrfaos(DateTime agora) async {
    final candidatos = <String>[];
    final duplicatasACobrir = <ItemBackup>[];
    for (final id in _emFila) {
      final item = _itemDoJob[id];
      final ok = _enviadosIds.contains(id) ||
          _emAndamento.contains(id) ||
          _naFila.contains(id) ||
          _preparando.contains(id) ||
          _processando.contains(id) ||
          _emRetomavel.contains(id) ||
          _falhos.containsKey(id);
      if (ok) {
        _ausentesDesde.remove(id);
        continue;
      }
      if (item != null && item.dup.isNotEmpty) {
        // Duplicata: depende do principal. Principal já no Drive = cobre.
        if (_enviadosIds.contains(item.dup)) duplicatasACobrir.add(item);
        continue;
      }
      final desde = _ausentesDesde.putIfAbsent(id, () => agora);
      if (agora.difference(desde) > const Duration(seconds: 45)) {
        candidatos.add(id);
      }
    }
    if (duplicatasACobrir.isNotEmpty) {
      await _cobrirDuplicatas(duplicatasACobrir);
    }
    var voltaram = 0;
    for (final id in candidatos) {
      final st = await BackupService.statusDe(id);
      if (st == TaskStatus.complete) {
        await _confirmarEnvio(id, null, null);
      } else if (st == TaskStatus.running ||
          st == TaskStatus.enqueued ||
          st == TaskStatus.waitingToRetry ||
          st == TaskStatus.paused) {
        continue; // ainda vivo no motor; confere na próxima varredura
      } else {
        _ausentesDesde.remove(id);
        final item = _itemDoJob[id];
        if (item != null) {
          _porNaFila(item);
          voltaram++;
        }
      }
    }
    if (voltaram > 0) _ev('Varredura: $voltaram arquivo(s) esquecido(s) voltaram pra fila');
  }
  /// Cobre duplicatas cujo principal já está no Drive (mesmo fileId).
  Future<void> _cobrirDuplicatas(Iterable<ItemBackup> dups) async {
    final lote = <NovoEnvio>[];
    for (final cob in dups) {
      if (_enviadosIds.contains(cob.id)) continue;
      if (!_enviadosIds.contains(cob.dup)) continue;
      final principal = _store.envioDe(cob.dup);
      lote.add((
        id: cob.id,
        fileId: principal?.fileId,
        bytes: cob.bytes > 0 ? cob.bytes : null,
        // MD5 igual ao do principal (é a regra da duplicata): se o principal
        // foi conferido no Drive, este também está.
        verificado: principal?.verificado ?? false,
      ));
      _enviadosIds.add(cob.id);
    }
    if (lote.isEmpty) return;
    await _store.marcarEnviadosEmLote(lote);
    _mudou();
    _checarConclusao();
  }
  /// Marca um arquivo como confirmado no Drive: store, contagem, velocidade,
  /// cobertura das duplicatas e limpeza do registro no banco da biblioteca.
  Future<void> _confirmarEnvio(String id, String? fileId, int? bytes,
      {bool contarVelocidade = true, bool verificado = false}) async {
    if (_enviadosIds.contains(id)) {
      // Já contado (ex.: a reconciliação viu antes do evento). Se agora veio
      // o fileId do Drive, guarda: é ele que libera o apagar com segurança.
      if (fileId != null) {
        await _store.marcarEnviado(id,
            fileId: fileId, bytes: bytes, verificado: verificado);
        final cobertos = _dupsDe[id];
        if (cobertos != null) {
          await _store.marcarEnviadosEmLote([
            for (final c in cobertos)
              if (_enviadosIds.contains(c.id) &&
                  _store.envioDe(c.id)?.fileId == null)
                (id: c.id, fileId: fileId, bytes: null, verificado: verificado)
          ]);
        }
      }
      return;
    }
    // Marca ANTES de qualquer await: duas confirmações simultâneas do mesmo
    // id (evento ao vivo + reconciliação) não contam 2 vezes.
    _enviadosIds.add(id);
    _emAndamento.remove(id);
    _falhos.remove(id);
    _tentativas.remove(id);
    _tentativasRede.remove(id);
    _ausentesDesde.remove(id);
    final b = bytes ?? _bytesPorId[id] ?? 0;
    await _store.marcarEnviado(id,
        fileId: fileId, bytes: b > 0 ? b : null, verificado: verificado);
    if (contarVelocidade && _emFila.contains(id) && b > 0) {
      _amostras.add((DateTime.now(), b));
      _bytesSessao += b;
      _telemetria.registrar(b);
    }
    _paraLimpar[id] = DateTime.now();
    _arquivosSessao++;
    _redeVoltou(); // arquivo chegou: a rede está de pé
    // Duplicatas exatas cobertas por este arquivo: mesmo fileId no Drive.
    final cobertos = _dupsDe[id];
    if (cobertos != null) {
      final lote = <NovoEnvio>[];
      for (final cob in cobertos) {
        if (_enviadosIds.contains(cob.id)) continue;
        lote.add((
          id: cob.id,
          fileId: fileId,
          bytes: cob.bytes > 0 ? cob.bytes : null,
          verificado: verificado,
        ));
        _enviadosIds.add(cob.id);
      }
      await _store.marcarEnviadosEmLote(lote);
    }
    _mudou();
    _notificarProgresso();
    _checarConclusao();
    _agendarRefresh();
  }
  /// A sessão acabou de completar? Celebra (1 vez), registra a telemetria,
  /// limpa a notificação de progresso e o job (nada mais a retomar).
  void _checarConclusao() {
    if (_celebrado || _inicioSessao == null || _emFila.isEmpty) return;
    if (_bgFeitos < _bgTotal) return;
    _celebrado = true;
    _fimRegistrado = true;
    Nativo.limparNotificacao();
    BackupService.invalidarListagem(); // subiu coisa nova; a listagem mudou
    _calcStats();
    final bytesTotal = _cBytesTotal;
    _store.registrarSessao({
      'inicio': _inicioSessao!.toIso8601String(),
      'fim': DateTime.now().toIso8601String(),
      'arquivos': _bgTotal,
      'bytes': bytesTotal,
      'falhas': 0,
      'ultimoErro': _erroBg,
      ..._telemetria.resumo(),
    });
    _store.limparJob();
    _erroBg = null;
    _ev('Backup concluído: $_bgTotal arquivos, ${_fmt(bytesTotal)}');
    if (mounted) _mostrarVitoria(_bgTotal, bytesTotal);
  }
  /// Fim com falhas: nada mais andando e sobrou arquivo que não subiu.
  /// Registra a sessão uma vez e para a notificação "subindo".
  void _verificarFim() {
    if (_fimRegistrado || !_fimComFalhas || _inicioSessao == null) return;
    _fimRegistrado = true;
    Nativo.limparNotificacao();
    BackupService.invalidarListagem();
    _calcStats();
    _store.registrarSessao({
      'inicio': _inicioSessao!.toIso8601String(),
      'fim': DateTime.now().toIso8601String(),
      'arquivos': _bgTotal,
      'enviados': _cFeitos,
      'bytes': _cBytesTotal,
      'falhas': _bgTotal - _cFeitos,
      'ultimoErro': _erroBg,
      ..._telemetria.resumo(),
    });
    _ev('Backup parou com falhas: $_cFeitos de $_bgTotal · ${_falhos.length} falhos · último erro: ${_erroBg ?? '-'}');
  }
  /// Notificação do sistema com o número REAL ("4.312 de 19.000") e barra.
  /// Atualizada no máximo a cada 3s pra não afogar o NotificationManager.
  void _notificarProgresso() {
    if (_emFila.isEmpty || _inicioSessao == null || _fimRegistrado) return;
    final total = _bgTotal;
    final feitos = _bgFeitos;
    if (feitos >= total || _pausado) {
      Nativo.limparNotificacao();
      return;
    }
    final agora = DateTime.now();
    if (agora.difference(_ultimaNotif).inSeconds < 3) return;
    _ultimaNotif = agora;
    final eta = _eta(_cBytesTotal - _cBytesFeitos);
    final texto = _semRede
        ? 'Sem internet: continua sozinho quando a rede voltar'
        : (eta.isNotEmpty ? eta : 'Subindo…');
    Nativo.notificar(
        'Backup: ${_milhar(feitos)} de ${_milhar(total)}', texto, feitos, total);
  }
  Future<void> _alimentar() async {
    if (_alimentando) {
      _alimentarDeNovo = true;
      return;
    }
    if (_conta == null || _pausado || _pendentes.isEmpty) return;
    final espera = _esperarRedeAte;
    if (espera != null && DateTime.now().isBefore(espera)) return;
    _alimentando = true;
    final lote = <ItemBackup>[];
    try {
      // Snapshot fresco do motor: nunca enfileira 2x o mesmo arquivo (um
      // taskId repetido viraria arquivo duplicado no Drive).
      try {
        final ativos = await BackupService.idsAtivos();
        _emAndamento.addAll(ativos.where((id) => !_enviadosIds.contains(id)));
      } catch (e) {
        falhaEngolida('alimentar/idsAtivos', e);
      }

      var emVoo = _emAndamento.length + _preparando.length;
      var bytesEmVoo = 0;
      for (final id in _emAndamento) {
        bytesEmVoo += _bytesPorId[id] ?? 0;
      }
      for (final id in _preparando) {
        bytesEmVoo += _bytesPorId[id] ?? 0;
      }
      while (emVoo < _janelaMax && _pendentes.isNotEmpty) {
        final prox = _pendentes.first;
        if (emVoo >= _janelaMin && bytesEmVoo + prox.bytes > _janelaBytes) {
          break;
        }
        final item = _tirarDaFila()!;
        if (item.dup.isNotEmpty ||
            _enviadosIds.contains(item.id) ||
            _emAndamento.contains(item.id) ||
            _preparando.contains(item.id) ||
            _processando.contains(item.id) ||
            _emRetomavel.contains(item.id) ||
            !_emFila.contains(item.id)) {
          continue;
        }
        // Motor novo: arquivo grande sobe em partes, com retomada.
        if (_motorNovo &&
            _retomavel != null &&
            item.bytes >= _minRetomavel &&
            item.path.isNotEmpty &&
            _emRetomavel.length < _maxRetomavelJuntos) {
          _emRetomavel.add(item.id);
          emVoo++;
          bytesEmVoo += item.bytes;
          unawaited(_enviarRetomavel(item));
          continue;
        }
        lote.add(item);
        _preparando.add(item.id);
        emVoo++;
        bytesEmVoo += item.bytes;
      }
      if (lote.isEmpty) return;

      await BackupService.garantirSubpastas(_gsi, lote.map((e) => e.pasta));

      var i = 0;
      while (i < lote.length) {
        if (_pausado) break;
        final leva = lote.sublist(i, min(i + _concorrenciaPreparo, lote.length));
        i += leva.length;
        final res = await Future.wait(leva.map((item) async {
          // Re-tentativa: o Drive pode ter recebido tudo e só a resposta se
          // perdeu. Confere antes (1 chamada barata) pra não duplicar.
          // Arquivo que chegou corrompido fica de fora: lá o tamanho bate.
          final jaTentou = (_tentativas[item.id] ?? 0) > 0 ||
              (_tentativasRede[item.id] ?? 0) > 0;
          if (jaTentou && !_corrompidos.contains(item.id)) {
            final achado = await BackupService.acharNoDrive(_gsi, item);
            if (achado != null) {
              final (fid, md5Drive) = achado;
              // Confere o conteúdo quando dá: MD5 diferente = é outro arquivo
              // com o mesmo nome e tamanho; sobe normalmente.
              String? md5Local;
              if (md5Drive != null &&
                  item.path.isNotEmpty &&
                  item.bytes <= _tetoMd5) {
                md5Local = _md5Cache[item.id] ?? await Nativo.md5(item.path);
              }
              if (md5Local == null || md5Local == md5Drive) {
                final v = md5Local != null ? 'v' : '';
                return (item: item, ok: false, erro: '$_prefixoJa$v:$fid');
              }
            }
          }
          final t0 = DateTime.now();
          final (ok, erro) = await BackupService.enfileirarUm(_gsi, item,
              soWifi: _soWifi, transferenciaLonga: _transferenciaLonga);
          _telemetria.preparo(DateTime.now().difference(t0));
          return (item: item, ok: ok, erro: erro);
        }));
        var driveCheio = false;
        var falhaDeRede = false;
        var algumOk = false;
        final devolver = <ItemBackup>[];
        for (final r in res) {
          final id = r.item.id;
          _preparando.remove(id);
          if (r.ok) {
            _emAndamento.add(id);
            algumOk = true;
            continue;
          }
          final erro = r.erro;
          if (erro != null && erro.startsWith(_prefixoJa)) {
            // Já estava no Drive: confirma sem subir.
            _ev('Já estava no Drive (resposta perdida antes): "${r.item.titulo}"');
            final resto = erro.substring(_prefixoJa.length);
            final sep = resto.indexOf(':');
            await _confirmarEnvio(
                id, resto.substring(sep + 1), r.item.bytes,
                contarVelocidade: false,
                verificado: resto.substring(0, sep) == 'v');
            algumOk = true;
            continue;
          }
          if (erro == BackupService.erroDriveCheio) {
            devolver.add(r.item);
            driveCheio = true;
          } else if (erro == BackupService.erroSumiu) {
            _tirarDaSessao(id);
            _ev('Sumiu da galeria, saiu do backup: "${r.item.titulo}"');
          } else if (BackupService.ehRede(erro)) {
            // Rede/limite do Drive: volta pra frente SEM gastar tentativa.
            devolver.add(r.item);
            falhaDeRede = true;
            _erroBg = null;
          } else {
            final t = (_tentativas[id] ?? 0) + 1;
            _tentativas[id] = t;
            if (t <= 3) {
              _porNaFila(r.item); // volta pro fim da fila
            } else {
              _falhos[id] = r.item;
              _motivoFalha[id] = mensagemAmigavel(erro);
              _telemetria.falhasDefinitivas++;
              if (erro != null && erro.isNotEmpty) _erroBg = erro;
              _ev('Falhou ao preparar: "${r.item.titulo}" · $erro');
            }
          }
        }
        _devolverNaFrente(devolver);
        if (_pausado) {
          // Parar chegou enquanto esta leva abria sessões: o que entrou na
          // fila do Android agora sai, senão subiria mesmo pausado.
          final entraram = [
            for (final r in res)
              if (r.ok) r.item.id
          ];
          if (entraram.isNotEmpty) {
            await BackupService.cancelar(entraram);
            _emAndamento.removeAll(entraram);
          }
          break;
        }
        if (algumOk) _redeVoltou();
        if (driveCheio) {
          await _pausarPorDriveCheio();
          break;
        }
        if (falhaDeRede && !algumOk) {
          _esperarRede();
          break;
        }
      }
      _mudou();
      _agendarRefresh();
    } catch (_) {
      // silencioso: tenta de novo no próximo tick
    } finally {
      // O que saiu da fila e não chegou a ser enfileirado volta pra frente.
      final sobra = lote.where((it) => _preparando.contains(it.id)).toList();
      for (final it in sobra) {
        _preparando.remove(it.id);
      }
      _devolverNaFrente(sobra);
      _alimentando = false;
      _verificarFim();
    }
    if (_alimentarDeNovo) {
      _alimentarDeNovo = false;
      unawaited(_alimentar());
    }
  }
  /// Motor novo: sobe UM arquivo grande em partes. Rede caiu, app fechou,
  /// Parar: a sessão fica salva e a próxima tentativa continua de onde parou.
  Future<void> _enviarRetomavel(ItemBackup item) async {
    final id = item.id;
    _agendarRefresh();
    try {
      final t0 = DateTime.now();
      final r = await _retomavel!.enviar(
        id,
        item.path,
        criarSessao: () => BackupService.criarSessaoPara(_gsi, item),
        cancelado: () => _pausado || _conta == null,
      );
      _telemetria.preparo(DateTime.now().difference(t0));
      switch (r.fim) {
        case FimUpload.ok:
          String? motivo;
          var verificou = false;
          if (r.bytes != null && item.bytes > 0 && r.bytes != item.bytes) {
            motivo = 'tamanho';
          } else if (r.md5 != null && item.bytes <= _tetoMd5) {
            final ml = await Nativo.md5(item.path);
            if (ml != null && ml != r.md5) motivo = 'md5';
            if (ml != null && ml == r.md5) verificou = true;
          }
          if (motivo != null) {
            final fid = r.fileId;
            if (fid != null) unawaited(BackupService.apagarNoDrive(_gsi, fid));
            _corrompidos.add(id);
            final t = (_tentativas[id] ?? 0) + 1;
            _tentativas[id] = t;
            _ev('Motor novo: chegou diferente ($motivo), tentativa $t: "${item.titulo}"');
            if (t <= 3) {
              _porNaFila(item, frente: true);
            } else {
              _falhos[id] = item;
              _motivoFalha[id] = 'Chegou diferente no Drive 3 vezes';
              _telemetria.falhasDefinitivas++;
            }
          } else {
            _ev('Motor novo: subiu em partes "${item.titulo}" (${_fmt(item.bytes)})');
            await _confirmarEnvio(id, r.fileId, r.bytes ?? item.bytes,
                verificado: verificou);
          }
        case FimUpload.cancelado:
          // Parar: a fila é refeita pelo Retomar; o que já foi fica salvo.
          _ev('Motor novo: pausado no meio de "${item.titulo}", continua depois');
        case FimUpload.rede:
        case FimUpload.sessaoInvalida:
          _telemetria.retentativasRede++;
          _porNaFila(item, frente: true);
          if (r.fim == FimUpload.rede) _esperarRede();
        case FimUpload.erro:
          final t = (_tentativas[id] ?? 0) + 1;
          _tentativas[id] = t;
          _ev('Motor novo: erro em "${item.titulo}": ${r.erro}');
          if (t <= 3) {
            _porNaFila(item);
          } else {
            _falhos[id] = item;
            _motivoFalha[id] = mensagemAmigavel(r.erro);
            _telemetria.falhasDefinitivas++;
            _erroBg = r.erro;
          }
      }
    } catch (e) {
      _ev('Motor novo: exceção em "${item.titulo}": $e');
      _porNaFila(item, frente: true);
    } finally {
      _emRetomavel.remove(id);
      _mudou();
      _agendarRefresh();
      _verificarFim();
      unawaited(_tick());
    }
  }
  /// Sem rede: espera crescente (15s, 30s, 1 min… até 5 min) antes de tentar
  /// preparar de novo. Antes, cada queda de rede queimava as 3 tentativas
  /// dos últimos arquivos em poucos minutos e eles viravam "falhou".
  void _esperarRede() {
    final ate = _esperarRedeAte;
    if (ate != null && DateTime.now().isBefore(ate)) {
      return; // já esperando: 40 falhas juntas não viram 40 dobras de espera
    }
    if (!_semRede) _ev('Sem rede: motor esperando a conexão voltar');
    final prox = _esperaRede == Duration.zero
        ? const Duration(seconds: 15)
        : _esperaRede * 2;
    _esperaRede =
        prox > const Duration(minutes: 5) ? const Duration(minutes: 5) : prox;
    _esperarRedeAte = DateTime.now().add(_esperaRede);
    _semRede = true;
    _timerRede?.cancel();
    _timerRede = Timer(_esperaRede, () => _tick());
    _agendarRefresh();
  }
  void _redeVoltou() {
    if (!_semRede && _esperaRede == Duration.zero) return;
    if (_semRede) _ev('Rede voltou');
    _semRede = false;
    _esperaRede = Duration.zero;
    _esperarRedeAte = null;
    _timerRede?.cancel();
  }
  /// Tira um item da sessão (o arquivo não existe mais no celular). Se era
  /// principal de duplicatas, a primeira duplicata vira o novo principal.
  void _tirarDaSessao(String id) {
    _emFila.remove(id);
    _itemDoJob.remove(id);
    _bytesPorId.remove(id);
    _falhos.remove(id);
    _tentativas.remove(id);
    _ausentesDesde.remove(id);
    _sumidos.add(id);
    final dups = _dupsDe.remove(id);
    if (dups != null && dups.isNotEmpty) {
      final novo = dups.first.comDup('');
      _itemDoJob[novo.id] = novo;
      final resto = [for (final d in dups.skip(1)) d.comDup(novo.id)];
      for (final d in resto) {
        _itemDoJob[d.id] = d;
      }
      if (resto.isNotEmpty) _dupsDe[novo.id] = resto;
      _porNaFila(novo, frente: true);
    }
    _mudou();
  }
  Future<void> _pausarPorDriveCheio() async {
    _ev('Drive cheio: backup pausado');
    await _store.setPausado(true);
    Nativo.limparNotificacao();
    if (mounted) {
      _set(() {
        _pausado = true;
        _driveCheio = true;
        _erroBg =
            'O Drive encheu. Libere espaço na conta (ou assine mais) e toque em Retomar.';
      });
    }
  }
  Future<void> _prepararJobGrande(int precisa) async {
    if (precisa < 5 * 1024 * 1024 * 1024) return;
    final isenta = await Nativo.bateriaIsenta();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup grande'),
        content: Text(
            'São ${_fmt(precisa)}. Isso leva horas, então:\n\n'
            '1. Deixe o celular na tomada.\n'
            '2. Deixe o app aberto (pode apagar a tela).\n'
            '${isenta ? '' : '3. Permita que o app ignore a economia de bateria, senão o Android pode pausar o backup de madrugada.'}'),
        actions: [
          if (!isenta)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await Nativo.pedirIsencaoBateria();
              },
              child: const Text('Permitir bateria'),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Entendi')),
        ],
      ),
    );
  }
  Future<List<ItemBackup>?> _apararPraCaber(
      List<ItemBackup> pendentes, int precisa, int livre) async {
    final (cabem, soma) = apararPraCaber(pendentes, livre);
    if (!mounted) return null;
    if (cabem.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('O Drive está cheio'),
          content: Text(
              'Você marcou ${_fmt(precisa)}, mas só tem ${_fmt(max(0, livre))} livres. Libere espaço no Drive (ou assine mais) e tente de novo.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      return null;
    }
    final escolha = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Não cabe tudo no Drive'),
        content: Text(
            'Você marcou ${_fmt(precisa)}, mas só tem ${_fmt(livre)} livres.\n\n'
            'Posso subir só o que cabe: ${_milhar(cabem.length)} arquivos (${_fmt(soma)}), começando pelos maiores. O resto fica pra depois que você liberar espaço.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Subir o que cabe')),
        ],
      ),
    );
    if (escolha != true) return null;
    return cabem;
  }
  /// Reconhece no Drive arquivos que já estão lá (nome + pasta + tamanho) e
  /// marca como enviados sem subir de novo. Cobre: reinstalação do app, kill
  /// no instante em que um upload terminava, Parar no fim de um arquivo.
  Future<int> _reconhecerNoDrive(Iterable<ItemBackup> candidatos) async {
    final lista = candidatos
        .where((it) => it.bytes > 0 && !_enviadosIds.contains(it.id))
        .toList();
    if (lista.isEmpty) return 0;
    // Só as pastas que interessam (cache por pasta no serviço).
    // Rodada 18: inclui o nome antigo da pasta (antes da mudança de nome).
    final noDrive = await BackupService.listarNoDrive(_gsi,
        pastas: {for (final it in lista) ...pastasPossiveis(it.pasta)});
    if (noDrive == null || noDrive.isEmpty) return 0;
    final porChave = <String, ArquivoDrive>{};
    for (final a in noDrive) {
      porChave['${a.nome}|${a.pasta}|${a.bytes}'] = a;
    }
    final usados = <String>{}; // 1 arquivo do Drive cobre 1 do celular
    final novos = <NovoEnvio>[];
    for (final it in lista) {
      ArquivoDrive? a;
      for (final p in pastasPossiveis(it.pasta)) {
        final x = porChave['${it.titulo}|$p|${it.bytes}'];
        if (x != null && !usados.contains(x.fileId)) {
          a = x;
          break;
        }
      }
      if (a == null) continue;
      usados.add(a.fileId);
      // Só nome+pasta+tamanho: NÃO verificado. O apagar confere o MD5 antes
      // de tirar do celular, e devolve pro backup se não bater.
      novos.add((id: it.id, fileId: a.fileId, bytes: it.bytes, verificado: false));
      _enviadosIds.add(it.id);
    }
    if (novos.isEmpty) return 0;
    await _store.marcarEnviadosEmLote(novos);
    await _store.gravarAgora();
    _mudou();
    return novos.length;
  }
  Future<void> _subir() async {
    if (_subindoAgora) return;
    if (_conta == null) {
      await _login(); // abre o login aqui mesmo e segue
      if (_conta == null || !mounted) return;
    }
    _subindoAgora = true;
    try {
      await _subirInterno();
    } finally {
      _subindoAgora = false;
    }
  }
  Future<void> _subirInterno() async {
    final (ok, erroCtx) = await BackupService.prepararContexto(_gsi);
    if (!ok) {
      if (!mounted) return;
      _ev('Não começou: $erroCtx');
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Não consegui começar o backup'),
          content: Text(BackupService.ehRede(erroCtx)
              ? 'Sem conexão com o Google agora. Confira a internet e tente de novo.'
              : mensagemAmigavel(erroCtx)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          duration: Duration(seconds: 2),
          content: Text('Conferindo o que já está no Drive…')));
    }

    final selecionados = _selected.map((m) => m.paraBackup()).toList();

    final jobAtual = await _store.job();
    final sessaoTerminou =
        _emFila.isNotEmpty && _emFila.every(_enviadosIds.contains);
    final Map<String, ItemBackup> mapa = {};
    if (!sessaoTerminou) {
      for (final m in jobAtual) {
        final it = ItemBackup.fromMap(m);
        if (it.id.isNotEmpty) mapa[it.id] = it;
      }
    }
    for (final it in selecionados) {
      mapa[it.id] = it; // seleção nova sobrescreve (dup é recalculado abaixo)
    }

    // Já está no Drive (backup anterior, reinstalação, kill no fim de um
    // upload)? Marca sem subir de novo. Store vazio = confere a galeria toda.
    final achados = await _reconhecerNoDrive(_enviadosIds.isEmpty
        ? _items.map((m) => m.paraBackup())
        : mapa.values);
    if (achados > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Achei ${_milhar(achados)} arquivos que já estavam no Drive. Eles não sobem de novo.')));
    }

    var mergedItens = mapa.values.toList();
    var pendentesItens = [
      for (final it in mergedItens)
        if (!_enviadosIds.contains(it.id)) it.comDup('')
    ];
    if (pendentesItens.isEmpty) {
      if (!mounted) return;
      _set(() => _mudou());
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Tudo que você marcou já está no Drive.')));
      return;
    }

    // Duplicatas exatas (clássico do WhatsApp): sobe 1, as outras são
    // cobertas pelo mesmo arquivo do Drive. Rodada 12: só é duplicata se o
    // MD5 for igual. Antes bastava nome + tamanho, e um arquivo DIFERENTE com
    // o mesmo nome e tamanho era marcado como salvo sem nunca subir.
    final enviadosNoCelular = [
      for (final m in _items)
        if (m.bytes > 0 && _enviadosIds.contains(m.id)) m.paraBackup()
    ];
    final grupos = gruposCandidatos<ItemBackup>(
        [...pendentesItens, ...enviadosNoCelular],
        (i) => i.titulo,
        (i) => i.bytes);
    final paraMd5 = [
      for (final g in grupos)
        for (final it in g)
          if (it.path.isNotEmpty && it.bytes <= _tetoMd5) it
    ];
    final md5s = await _md5DeVarios(paraMd5,
        titulo: 'Conferindo arquivos repetidos…');
    if (md5s == null) return; // usuário cancelou
    final jaEnviados = <String, String>{
      for (final it in enviadosNoCelular)
        if (md5s[it.id] != null) chaveDup(it.titulo, it.bytes, md5s[it.id]): it.id
    };
    final (comDups, duplicatas) =
        marcarDuplicatas(pendentesItens, jaEnviados: jaEnviados, md5: md5s);
    pendentesItens = comDups;

    // Checa espaço: só o que de fato sobe (duplicata coberta não conta).
    final precisa = pendentesItens
        .where((it) => it.dup.isEmpty)
        .fold<int>(0, (s, it) => s + it.bytes);
    final livre = await BackupService.espacoLivre(_gsi);
    if (livre != null && precisa > livre) {
      final soSobem = pendentesItens.where((it) => it.dup.isEmpty).toList();
      final aparados = await _apararPraCaber(soSobem, precisa, livre);
      if (aparados == null || aparados.isEmpty) return;
      final idsAparados = aparados.map((e) => e.id).toSet();
      // Ficam: os aparados + as duplicatas cujo principal ficou (ou já subiu).
      pendentesItens =
          manterAparados(pendentesItens, idsAparados, _enviadosIds.contains);
    }
    mergedItens = [
      ...mergedItens.where((it) => _enviadosIds.contains(it.id)),
      ...pendentesItens,
    ];

    await _prepararJobGrande(pendentesItens
        .where((it) => it.dup.isEmpty)
        .fold<int>(0, (s, it) => s + it.bytes));

    // Grandes em ordem decrescente (liberam espaço mais cedo), intercalados
    // com levas de fotos pequenas: rede e custo por arquivo ocupados juntos.
    final fila = ordenarFila(pendentesItens.where((it) => it.dup.isEmpty));

    await _store.salvarJob(mergedItens.map((e) => e.toMap()).toList());
    await _store.setPausado(false);
    BackupService.invalidarListagem();

    if (!mounted) return;
    _set(() {
      _pausado = false;
      _driveCheio = false;
      _falhos.clear();
      _erroBg = null;
      _tentativas.clear();
      _tentativasRede.clear();
      _ausentesDesde.clear();
      _amostras.clear();
      _bytesSessao = 0;
      _arquivosSessao = 0;
      _inicioSessao = DateTime.now();
      _telemetria.zerar();
      _celebrado = false;
      _fimRegistrado = false;
      _semeado = true;
      _redeVoltou();
      _carregarSessao(mergedItens);
      _limparFila();
      for (final it in fila) {
        _porNaFila(it);
      }
      _mudou();
    });
    // Duplicata cujo principal JÁ está no Drive: cobre agora, senão a
    // contagem da sessão nunca fecharia esperando um upload que não existe.
    await _cobrirDuplicatas(pendentesItens.where((it) => it.dup.isNotEmpty));
    if (!mounted) return;
    final msgDup = duplicatas > 0
        ? ' ${_milhar(duplicatas)} duplicatas sobem 1 vez só (poupa Drive).'
        : '';
    _ev('Backup começou: ${fila.length} arquivos pra subir, $duplicatas duplicatas, ${_fmt(precisa)}, já no Drive: $achados');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Backup começou.$msgDup')));
    _tick();
  }
  /// Monta o estado da sessão (denominador, bytes, itens e duplicatas).
  void _carregarSessao(List<ItemBackup> itens) {
    final ids = itens.map((e) => e.id).toSet();
    _emFila
      ..clear()
      ..addAll(ids);
    _bytesPorId
      ..clear()
      ..addEntries(itens.map((e) => MapEntry(e.id, e.bytes)));
    _itemDoJob
      ..clear()
      ..addEntries(itens.map((e) => MapEntry(e.id, e)));
    _dupsDe.clear();
    for (final it in itens) {
      // Duplicata cujo principal não está mais no job vira principal.
      if (it.dup.isNotEmpty && !ids.contains(it.dup)) {
        _itemDoJob[it.id] = it.comDup('');
        continue;
      }
      if (it.dup.isNotEmpty) {
        _dupsDe.putIfAbsent(it.dup, () => []).add(it);
      }
    }
    _mudou();
  }
  Future<void> _parar() async {
    await _store.setPausado(true);
    Nativo.limparNotificacao();
    if (!mounted) return;
    _set(() {
      _pausado = true;
      _limparFila();
      _mudou();
    });
    _ev('Parar (usuário)');
    // Cancela o que já estava na fila do Android. Com janela de 40 (vários
    // vídeos grandes), "deixar terminar" podia levar horas.
    await BackupService.cancelarTodos();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Backup pausado. O que já subiu está salvo; Retomar continua de onde parou.')));
    _tick();
  }
  Future<void> _retomar() async {
    if (_retomando) return;
    _retomando = true;
    try {
      await _retomarInterno();
    } finally {
      _retomando = false;
    }
  }
  Future<void> _retomarInterno() async {
    await _store.setPausado(false);
    if (!mounted) return;
    _set(() {
      _pausado = false;
      _driveCheio = false;
      _erroBg = null;
      _semeado = false;
      _fimRegistrado = false;
      _redeVoltou();
    });
    final job = await _store.job();
    // Algum arquivo pode ter terminado no instante do Parar: confere no Drive
    // antes de re-subir (evita duplicata).
    await _reconhecerNoDrive(job.map(ItemBackup.fromMap));
    await _retomarJanela(job);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Retomando de onde parou.')));
  }
  Future<void> _tentarFalhosDeNovo() async {
    if (_falhos.isEmpty) return;
    _set(() {
      for (final it in _falhos.values) {
        _tentativas.remove(it.id);
        _porNaFila(it);
      }
      _falhos.clear();
      _erroBg = null;
      _fimRegistrado = false;
      _redeVoltou();
      _mudou();
    });
    _tick();
  }
  Future<void> _iniciarBackupEngine() async {
    if (_sub != null) return; // já ligado
    try {
      await BackupService.configurar();
      _sub = FileDownloader().updates.listen(_onUpdate);
      await BackupService.iniciarMotor();

      // O que terminou com o app fechado (o banco da biblioteca sabe).
      // (Os que estão sendo conferidos agora pelo evento ao vivo ficam de fora:
      // a conferência de MD5 decide.)
      final concluidos = (await BackupService.concluidosNoBanco())
          .where((id) => !_processando.contains(id))
          .toSet();
      if (concluidos.isNotEmpty) {
        await _store.marcarEnviadosEmLote(
            [
              for (final id in concluidos)
                (id: id, fileId: null, bytes: null, verificado: false)
            ]);
        _enviadosIds.addAll(concluidos);
        final agora = DateTime.now();
        for (final id in concluidos) {
          _paraLimpar[id] = agora;
        }
        await _store.gravarAgora();
      }

      if (await _store.precisaLimparFila()) {
        await BackupService.limparFilaLegada();
        await _store.marcarFilaLimpa();
      }
    } catch (e) {
      falhaEngolida('limpar fila antiga', e);
    }

    try {
      final conta = await _gsi
          .signInSilently()
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
      _ultimoLoginSilencioso = DateTime.now();
      if (conta != null && mounted) _set(() => _conta = conta);
    } catch (_) {}

    final job = await _store.job();
    final pausado = await _store.pausado();
    final soWifi = await _store.soWifi();
    final motorNovo = await _store.flag(UploadStore.kMotorNovo);
    final transfLonga = await _store.flag(UploadStore.kTransferenciaLonga);
    final lixeira = await _store.flag(UploadStore.kLixeira);
    final dicaVista = await _store.flag(UploadStore.kDicaAberto);
    final sdk = await Nativo.sdk();
    if (!mounted) return;
    _set(() {
      _lixeira = lixeira;
      _dicaAbertoVista = dicaVista;
      _sdk = sdk;
      _pausado = pausado;
      _soWifi = soWifi;
      _motorNovo = motorNovo;
      _transferenciaLonga = transfLonga;
      if (job.isNotEmpty) {
        _carregarSessao(job.map(ItemBackup.fromMap).toList());
        _inicioSessao ??= DateTime.now();
      }
      _mudou();
    });
    _motorPronto = true;
    _ev('Abriu o app $_versao: ${_enviadosIds.length} enviados no store, job com ${job.length}, ${pausado ? 'pausado' : 'ativo'}, conta ${_conta != null ? 'ok' : 'ausente'}');
    _tentarRetomar();
  }
  /// Retoma a sessão salva quando motor, galeria e conta estão prontos.
  Future<void> _tentarRetomar() async {
    if (_semeado ||
        _retomando ||
        !_motorPronto ||
        !_galeriaPronta ||
        _conta == null) {
      return;
    }
    if (_pausado) {
      _semeado = true; // nada a semear; Retomar reconstrói
      return;
    }
    _retomando = true;
    try {
      final job = await _store.job();
      await _retomarJanela(job);
    } finally {
      _retomando = false;
    }
  }
  Future<void> _retomarJanela(List<Map<String, String>> job) async {
    if (_conta == null || _pausado) return;
    if (job.isEmpty) {
      _semeado = true;
      return;
    }
    var itens = job.map(ItemBackup.fromMap).where((it) => it.id.isNotEmpty);

    // Poda: ids do job que não existem mais na galeria (apagados por fora).
    // Só com acesso total: com acesso parcial a galeria mostra só uma parte.
    if (_acessoTotal && _galeriaPronta && _items.isNotEmpty) {
      final naGaleria = {for (final m in _items) m.id};
      final sumidos = <String>{
        for (final it in itens)
          if (!naGaleria.contains(it.id) && !_enviadosIds.contains(it.id))
            it.id
      };
      if (sumidos.isNotEmpty) {
        await _store.removerDoJob(sumidos);
        itens = itens.where((it) => !sumidos.contains(it.id));
      }
    }
    final lista = itens.toList();
    if (!mounted) return;
    _carregarSessao(lista);

    // Duplicatas cujo principal já pagou: cobre agora.
    await _cobrirDuplicatas(
        lista.where((it) => it.dup.isNotEmpty && _itemDoJob[it.id]?.dup != ''));

    // Snapshot do motor antes de semear: o que já está na fila do Android
    // não volta pra nossa fila.
    try {
      final ativos = await BackupService.idsAtivos();
      _emAndamento
        ..clear()
        ..addAll(ativos.where((id) => !_enviadosIds.contains(id)));
    } catch (e) {
      falhaEngolida('reconciliar/idsAtivos', e);
    }

    final pendentes = ordenarFila([
      for (final id in _emFila)
        if (!_enviadosIds.contains(id) &&
            !_emAndamento.contains(id) &&
            (_itemDoJob[id]?.dup.isEmpty ?? false))
          _itemDoJob[id]!
    ]);
    if (!mounted) return;
    _ev('Retomada: ${pendentes.length} na fila, ${_emAndamento.length} já no motor, total ${_emFila.length}');
    _set(() {
      _semeado = true;
      _inicioSessao ??= DateTime.now(); // sessão retomada conta como ativa
      _limparFila();
      for (final it in pendentes) {
        _porNaFila(it);
      }
      _mudou();
    });
    _checarConclusao();
    if (pendentes.isNotEmpty) {
      await BackupService.prepararContexto(_gsi);
      _tick();
    }
  }
  void _onUpdate(TaskUpdate update) {
    if (update is! TaskStatusUpdate ||
        update.task.group != BackupService.grupo) {
      return;
    }
    _processarStatus(update);
  }
  Future<void> _processarStatus(TaskStatusUpdate update) async {
    try {
      await _processarStatusInterno(update);
    } catch (_) {
      // um evento com problema não pode derrubar o motor; a reconciliação
      // e a varredura de órfãos acertam o estado no próximo tick
    }
  }
  Future<void> _processarStatusInterno(TaskStatusUpdate update) async {
    final id = update.task.taskId;
    switch (update.status) {
      case TaskStatus.complete:
        await _concluido(update);
      case TaskStatus.failed:
      case TaskStatus.notFound:
        await _falhou(update);
      case TaskStatus.canceled:
        // Parar cancelou: não é falha. O Retomar reconstrói a fila.
        _emAndamento.remove(id);
        await BackupService.apagarCopiaDeCache(update.task);
        _agendarRefresh();
      default:
        break;
    }
  }
  Future<void> _concluido(TaskStatusUpdate update) async {
    final id = update.task.taskId;
    if (_processando.contains(id)) return;
    _processando.add(id);
    try {
      final (fileId, bytes, md5Drive) =
          BackupService.extrairArquivoDaResposta(update.responseBody);
      final meta = MetaTarefa.decodificar(update.task.metaData);

      // Integridade: o tamanho no Drive tem que bater com o arquivo local
      // (vale pra todos, inclusive vídeos grandes). E até 256 MB confere o
      // MD5 local contra o que o Drive calculou. Divergiu = refaz o upload.
      var verificou = false;
      if (!_enviadosIds.contains(id) && (bytes != null || md5Drive != null)) {
        String? motivo;
        try {
          final caminho = await update.task.filePath();
          final arq = File(caminho);
          final local = await arq.exists() ? await arq.length() : null;
          if (bytes != null && local != null && local > 0 && bytes != local) {
            motivo = 'tamanho';
          } else if (md5Drive != null &&
              local != null &&
              local > 0 &&
              local <= _tetoMd5) {
            final md5Local = await Nativo.md5(caminho);
            if (md5Local != null && md5Local != md5Drive) motivo = 'md5';
            if (md5Local != null && md5Local == md5Drive) {
              verificou = true;
              _md5Cache[id] = md5Local;
            }
          }
        } catch (_) {
          // sem conferência local não bloqueia: o tamanho do Drive vale
        }
        if (motivo != null) {
          await BackupService.apagarCopiaDeCache(update.task);
          if (fileId != null) {
            unawaited(BackupService.apagarNoDrive(_gsi, fileId));
          }
          _emAndamento.remove(id);
          final t = (_tentativas[id] ?? 0) + 1;
          _tentativas[id] = t;
          final item = _itemPara(id, update.task);
          _corrompidos.add(id);
          _ev('Chegou diferente no Drive ($motivo), tentativa $t: "${item.titulo}"');
          if (t <= 3) {
            _porNaFila(item, frente: true);
            _erroBg = 'Um arquivo chegou diferente no Drive; refazendo.';
          } else {
            _falhos[id] = item;
            _motivoFalha[id] = 'Chegou diferente no Drive 3 vezes';
            _telemetria.falhasDefinitivas++;
            _erroBg =
                '"${item.titulo}" chegou diferente no Drive 3 vezes (${meta.pasta}).';
          }
          _mudou();
          _agendarRefresh();
          return;
        }
      }

      await _confirmarEnvio(id, fileId, bytes, verificado: verificou);
      await BackupService.apagarCopiaDeCache(update.task);
    } finally {
      _processando.remove(id);
    }
    _tick();
  }
  Future<void> _falhou(TaskStatusUpdate update) async {
    final id = update.task.taskId;
    await BackupService.apagarCopiaDeCache(update.task);
    _emAndamento.remove(id);
    if (_enviadosIds.contains(id) || !_emFila.contains(id)) {
      _agendarRefresh();
      return;
    }
    final item = _itemPara(id, update.task);
    if (_pausado) {
      // Pausado: não gasta tentativa. O Retomar reconstrói a fila do job.
      _agendarRefresh();
      return;
    }
    final exc = update.exception;
    if (exc is TaskHttpException && exc.httpResponseCode == 403) {
      // 403 no PUT pode ser Drive cheio OU limite de taxa. Confere a cota
      // antes de pausar tudo (antes pausava com "Drive encheu" por engano).
      final livre = await BackupService.espacoLivre(_gsi);
      if (livre != null && livre < item.bytes + 50 * 1024 * 1024) {
        _porNaFila(item, frente: true);
        await _pausarPorDriveCheio();
        return;
      }
    }
    final codigo = exc is TaskHttpException ? exc.httpResponseCode : 0;
    final httpTransitorio = codigo == 429 || codigo >= 500 || codigo == 403;
    if (exc is TaskConnectionException || httpTransitorio) {
      // Rede caiu de vez durante o upload (a biblioteca já tinha tentado 10x),
      // ou o Drive pediu calma (429, 5xx, 403 de limite de taxa). Não gasta
      // tentativa normal: espera e tenta de novo, até 20x.
      final tr = (_tentativasRede[id] ?? 0) + 1;
      _tentativasRede[id] = tr;
      _telemetria.retentativasRede++;
      if (tr <= 20) {
        _porNaFila(item, frente: true);
        _esperarRede();
        _mudou();
        return;
      }
    }
    final t = (_tentativas[id] ?? 0) + 1;
    _tentativas[id] = t;
    if (t <= 3) {
      _porNaFila(item);
    } else {
      _falhos[id] = item;
      _telemetria.falhasDefinitivas++;
      final desc = exc?.description;
      _motivoFalha[id] = mensagemAmigavel(
          '${desc ?? ''} ${codigo > 0 ? 'HTTP $codigo' : ''} ${exc.runtimeType}');
      if (desc != null && desc.isNotEmpty) _erroBg = desc;
      _ev('Falhou de vez: "${item.titulo}" (${item.pasta}) · ${exc.runtimeType} $codigo · ${desc ?? ''}');
    }
    _mudou();
    _agendarRefresh();
    _tick();
  }
  /// Bytes/s. Janela dos últimos 10 min; com poucas amostras (vídeos grandes
  /// concluem raramente) cai pra média da sessão.
  double get _velocidade {
    final agora = DateTime.now();
    _amostras.removeWhere((a) => agora.difference(a.$1).inSeconds > 600);
    if (_amostras.length >= 3) {
      final bytes = _amostras.fold<int>(0, (s, a) => s + a.$2);
      final janela = agora.difference(_amostras.first.$1).inSeconds;
      if (janela >= 30) return bytes / janela;
    }
    final inicio = _inicioSessao;
    if (inicio != null && _bytesSessao > 0) {
      final seg = agora.difference(inicio).inSeconds;
      if (seg >= 60) return _bytesSessao / seg;
    }
    return 0;
  }
  /// Arquivos PEQUENOS por segundo (até 8 MB), na mesma janela. Com "maiores
  /// primeiro", o fim do backup são milhares de fotos: ali manda o custo por
  /// arquivo (abrir sessão, conferir), não a banda. Só vale com amostra.
  double get _pequenosPorSeg {
    final agora = DateTime.now();
    final peq = _amostras.where((a) => a.$2 < _pequeno).toList();
    if (peq.length < 5) return 0;
    final janela = agora.difference(peq.first.$1).inSeconds;
    return janela >= 30 ? peq.length / janela : 0;
  }
  String _eta(int bytesRestantes) => textoEta(estimarSegundos(
        bytesRestantes: bytesRestantes,
        bytesPorSeg: _velocidade,
        pequenosRestantes: _cPequenosRestantes,
        pequenosPorSeg: _pequenosPorSeg,
      ));
}
