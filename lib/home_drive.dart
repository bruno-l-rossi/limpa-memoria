part of 'main.dart';

// Rodada 18: saiu do main.dart (achado A-32).
// Conta do Google, espaço, apagar do celular e manutenção do Drive.

extension _ContaEDrive on _HomePageState {
  Future<void> _login() async {
    try {
      final conta = await _gsi.signIn();
      if (!mounted) return;
      _set(() => _conta = conta);
      if (conta != null) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Conectado como ${conta.email}')));
        _tick(); // retoma backup pendente, se houver
      }
    } catch (e) {
      _ev('Falha no login: $e');
      _avisar(mensagemAmigavel(e));
    }
  }
  /// Sair pede confirmação: antes um toque no ícone da conta deslogava na
  /// hora, inclusive no meio de um backup.
  Future<void> _logout() async {
    final subindo = _emFila.isNotEmpty && _bgFeitos < _bgTotal && !_pausado;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sair da conta Google?'),
        content: Text(subindo
            ? 'Tem um backup em andamento. Saindo, ele para até você entrar de novo. Nada do que já subiu se perde.'
            : 'O que já está no Drive continua lá. Pra subir ou apagar de novo, é só entrar outra vez.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sair')),
        ],
      ),
    );
    if (ok != true) return;
    await _gsi.signOut();
    if (!mounted) return;
    _set(() => _conta = null);
  }
  Future<void> _tentarLoginSilencioso() async {
    final agora = DateTime.now();
    if (agora.difference(_ultimoLoginSilencioso) < const Duration(minutes: 2)) {
      return;
    }
    _ultimoLoginSilencioso = agora;
    try {
      final conta = await _gsi
          .signInSilently()
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
      if (conta != null && mounted) _set(() => _conta = conta);
    } catch (_) {}
  }
  Future<void> _checarEspaco() async {
    String msg;
    try {
      final (usado, limite) = await BackupService.quota(_gsi);
      msg = limite == 0
          ? 'Usado: ${_fmt(usado)} (conta sem limite definido)'
          : 'Livre: ${_fmt(limite - usado)} de ${_fmt(limite)}';
    } catch (e) {
      msg = 'Não consegui ler o espaço do Drive agora. Confira a internet.';
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Espaço no Drive'),
        content: Text(msg),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }
  Future<void> _apagarEnviados() async {
    final itemPorId = {for (final m in _items) m.id: m};
    final candidatos =
        _enviadosIds.where(itemPorId.containsKey).toList(growable: false);
    if (candidatos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Nada confirmado no Drive ainda. Suba antes de apagar.')));
      return;
    }
    if (_conta == null) {
      await _login(); // sem conferir no Drive, nada é apagado
      if (_conta == null || !mounted) return;
    }

    final bytes = candidatos.fold<int>(0, (s, id) => s + itemPorId[id]!.bytes);
    // Rodada 18: com a opção ligada (Android 11+), vai pra lixeira da galeria.
    final praLixeira = _lixeira && _sdk >= 30;
    final confirma = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(praLixeira ? 'Mandar pra lixeira' : 'Apagar do celular'),
        content: Text(praLixeira
            ? 'Mandar ${_milhar(candidatos.length)} arquivos (${_fmt(bytes)}) pra lixeira do celular?\n\nAntes, o app confere um a um no Drive. O que não estiver conferido fica onde está.\n\nNa lixeira eles ficam 30 dias e dá pra restaurar pela galeria. O espaço volta quando a lixeira esvaziar.'
            : 'Apagar ${_milhar(candidatos.length)} arquivos (${_fmt(bytes)})?\n\nAntes de apagar, o app confere um a um no Drive. O que não estiver conferido fica no celular.\n\nO Android vai pedir confirmação em algumas levas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(praLixeira ? 'Conferir e mandar' : 'Conferir e apagar')),
        ],
      ),
    );
    if (confirma != true || !mounted) return;

    // Sem a permissão de localização da mídia, o Android entrega as fotos SEM
    // o GPS do EXIF: o que subiu pode estar sem o "onde". Não apaga assim.
    if (!await Nativo.localizacaoMidiaPermitida()) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Falta uma permissão'),
          content: const Text(
              'O app não tem acesso à localização das fotos. Sem ela, o Android entrega as fotos sem o lugar onde foram tiradas, e o backup pode ter ido sem essa informação.\n\nPor segurança, nada é apagado enquanto essa permissão estiver desligada. Libere em Ajustes > Permissões > Fotos e vídeos.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Agora não')),
            FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  PhotoManager.openSetting();
                },
                child: const Text('Abrir ajustes')),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;

    final nav = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('Conferindo no Drive…')),
          ]),
        ),
      ),
    );
    // A conferência de um apagar é SEMPRE com a listagem fresca.
    BackupService.invalidarListagem();
    final noDrive = await BackupService.listarNoDrive(_gsi);
    nav.pop(); // fecha o "conferindo"
    if (!mounted) return;
    if (noDrive == null) {
      _avisar(
          'Não consegui conferir no Drive (internet?). Sem conferência, nada é apagado.');
      return;
    }

    // Monta os candidatos e calcula o MD5 local de quem ainda não foi
    // conferido por conteúdo (backups antigos, reconhecidos por nome,
    // concluídos com o app fechado).
    var candidatosApagar = [
      for (final id in candidatos)
        () {
          final item = itemPorId[id]!;
          final info = _store.envioDe(id);
          return CandidatoApagar(
            id: id,
            titulo: item.titulo,
            pasta: item.pasta,
            bytesAgora: item.bytes,
            fileId: info?.fileId,
            bytesEnviados: info?.bytes,
            verificado: info?.verificado ?? false,
          );
        }()
    ];
    final paraMd5 = [
      for (final c in candidatosApagar)
        if (precisaMd5(c, _tetoMd5)) itemPorId[c.id]!.paraBackup()
    ];
    if (paraMd5.isNotEmpty) {
      final md5s =
          await _md5DeVarios(paraMd5, titulo: 'Conferindo o conteúdo…');
      if (md5s == null || !mounted) return; // cancelou: nada apagado
      candidatosApagar = [
        for (final c in candidatosApagar)
          md5s[c.id] == null
              ? c
              : CandidatoApagar(
                  id: c.id,
                  titulo: c.titulo,
                  pasta: c.pasta,
                  bytesAgora: c.bytesAgora,
                  fileId: c.fileId,
                  bytesEnviados: c.bytesEnviados,
                  verificado: c.verificado,
                  md5Local: md5s[c.id],
                )
      ];
    }
    final decisao =
        decidirApagar(candidatosApagar, noDrive, tetoMd5: _tetoMd5);
    final verificados = decisao.pode;
    final naoConferidos = decisao.fica.length;

    // O que NÃO está no Drive de verdade (sumiu de lá, ou é outro arquivo com
    // o mesmo nome) volta a ser "fora do Drive" pra subir no próximo backup.
    // Sem isso ficava marcado como salvo pra sempre sem estar.
    final voltam = [
      for (final e in decisao.fica.entries)
        if (e.value == MotivoFica.naoAchado ||
            e.value == MotivoFica.md5Diferente)
          e.key
    ];
    if (voltam.isNotEmpty) {
      await _store.esquecerEnviados(voltam);
      _set(() {
        _enviadosIds.removeAll(voltam);
        _mudou();
      });
      _ev('Apagar: ${voltam.length} marcados como salvos não estavam no Drive; voltaram pro backup');
    }
    final motivos = <MotivoFica, int>{};
    for (final m in decisao.fica.values) {
      motivos[m] = (motivos[m] ?? 0) + 1;
    }
    if (motivos.isNotEmpty) {
      _ev('Apagar: ficaram ${motivos.entries.map((e) => '${e.key.name}=${e.value}').join(' ')}');
    }
    if (verificados.isEmpty) {
      _avisar(voltam.isNotEmpty
          ? 'Nada foi apagado. ${_milhar(voltam.length)} arquivos não estavam no Drive de verdade e voltaram pra lista do backup.'
          : 'Não consegui conferir nenhum arquivo no Drive. Nada foi apagado.');
      return;
    }
    // Lotes que cabem no limite do Android. Usuário recusou um lote = para.
    // Erro num lote (ex.: um arquivo sumiu no meio) = tenta em lotes menores.
    final apagadosAll = <String>[];
    var recusou = false;
    Future<bool> apagarLote(List<String> ids) async {
      try {
        final apag = praLixeira
            ? await PhotoManager.editor.android
                .moveToTrash([for (final id in ids) itemPorId[id]!.asset])
            : await PhotoManager.editor.deleteWithIds(ids);
        apagadosAll.addAll(apag);
        if (apag.isEmpty) recusou = true;
        return true;
      } catch (e) {
        _ev('Apagar: lote de ${ids.length} falhou ($e)');
        return false;
      }
    }

    const tamLote = 800;
    for (var i = 0; i < verificados.length && !recusou; i += tamLote) {
      final chunk = verificados.sublist(i, min(i + tamLote, verificados.length));
      final ok = await apagarLote(chunk);
      if (!ok) {
        for (var j = 0; j < chunk.length && !recusou; j += 100) {
          await apagarLote(chunk.sublist(j, min(j + 100, chunk.length)));
        }
      }
    }

    final setApagados = apagadosAll.toSet();
    await _store.esquecerEnviados(setApagados);
    // Tira do job também: senão a retomada tentava subir arquivos apagados.
    await _store.removerDoJob(setApagados);
    if (!mounted) return;
    _set(() {
      _items.removeWhere((m) => setApagados.contains(m.id));
      _enviadosIds.removeAll(setApagados);
      _selected.removeWhere((m) => setApagados.contains(m.id));
      _emFila.removeAll(setApagados);
      for (final id in setApagados) {
        _itemDoJob.remove(id);
        _bytesPorId.remove(id);
      }
      _ordenadoCache = null;
      _filtradoCache = null;
      _bytesNoCelular = _items.fold(0, (s, m) => s + m.bytes);
      _pastas = _agruparPastas(_items);
      _mudou();
    });
    final restam = verificados.length - setApagados.length;
    _ev('Apagar${praLixeira ? ' (lixeira)' : ''}: ${setApagados.length} saíram, $naoConferidos não conferiram, ${recusou ? 'usuário recusou um lote' : 'sem recusa'}');
    final liberados = setApagados.fold<int>(
        0, (soma, id) => soma + (itemPorId[id]?.bytes ?? 0));
    final extras = [
      if (recusou && restam > 0)
        '${_milhar(restam)} ficaram porque a confirmação do Android foi recusada.',
      if (naoConferidos > 0)
        '${_milhar(naoConferidos)} não conferiram no Drive e ficaram no celular, por segurança.',
    ];
    if (setApagados.isEmpty) {
      _avisar(['Nada foi apagado.', ...extras].join(' '));
      return;
    }
    // Fecha o ciclo com o ganho que o app promete: espaço livre.
    final total = await _store.somarLiberado(liberados);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.celebration_outlined, color: _actionBlue),
        title: Text(praLixeira
            ? '${_fmt(liberados)} na lixeira'
            : 'Você liberou ${_fmt(liberados)}'),
        content: Text([
          praLixeira
              ? '${_milhar(setApagados.length)} arquivos foram pra lixeira da galeria e continuam no seu Drive. O espaço volta quando a lixeira esvaziar (até 30 dias, ou na hora se você esvaziar pela galeria).'
              : '${_milhar(setApagados.length)} arquivos saíram do celular e continuam no seu Drive.',
          if (total > liberados) 'No total o app já liberou ${_fmt(total)}.',
          ...extras,
        ].join('\n\n')),
        actions: [
          TextButton(
            onPressed: () => Nativo.compartilhar(
                'Liberei ${_fmt(liberados)} do celular sem perder nenhuma foto, com o Limpa Memória.'),
            child: const Text('Compartilhar'),
          ),
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Ok')),
        ],
      ),
    );
  }
  /// Roda uma tarefa longa com diálogo de progresso e botão Cancelar.
  Future<T?> _comProgresso<T>(
      String titulo,
      Future<T> Function(
              void Function(int feitos, int total) progresso,
              bool Function() cancelado)
          tarefa) async {
    final prog = ValueNotifier<(int, int)>((0, 0));
    var cancelado = false;
    final nav = Navigator.of(context, rootNavigator: true);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(titulo),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: prog,
            builder: (_, v, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: v.$2 == 0 ? null : v.$1 / v.$2),
                const SizedBox(height: 8),
                Text(v.$2 == 0
                    ? 'Conferindo no Drive…'
                    : '${_milhar(v.$1)} de ${_milhar(v.$2)}'),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => cancelado = true,
                child: const Text('Cancelar')),
          ],
        ),
      ),
    ));
    try {
      return await tarefa((f, t) => prog.value = (f, t), () => cancelado);
    } finally {
      nav.pop();
      prog.dispose();
    }
  }
  /// O que já subiu e ainda está no celular, com o fileId gravado.
  List<ItemEnviado> _itensEnviados() => [
        for (final m in _items)
          if (_enviadosIds.contains(m.id))
            (item: m.paraBackup(), fileId: _store.envioDe(m.id)?.fileId)
      ];
  /// Pronto pra mexer no Drive? (conta ok e backup parado)
  Future<bool> _prontoPraManutencao() async {
    if (_trabalhando) {
      _avisar('Espere o backup terminar (ou pare) antes de mexer no Drive.');
      return false;
    }
    if (_conta == null) await _login();
    return _conta != null && mounted;
  }
  Future<void> _organizarPastas() async {
    if (!await _prontoPraManutencao()) return;
    final itens = _itensEnviados();
    final r = await _comProgresso('Organizando pastas no Drive',
        (p, c) => BackupService.organizarPastas(_gsi, itens,
            progresso: p, cancelado: c));
    if (!mounted) return;
    if (r == null) {
      _avisar('Não consegui ler o Drive (internet?). Nada foi mexido.');
      return;
    }
    final (movidos, falhas) = r;
    _ev('Organizar pastas: $movidos movidos, $falhas falhas');
    _avisar(movidos == 0 && falhas == 0
        ? 'Tudo já está na pasta certa.'
        : '${_milhar(movidos)} arquivos foram pra pasta nova.'
            '${falhas > 0 ? ' ${_milhar(falhas)} não deu; tente de novo depois.' : ''}');
  }
  Future<void> _corrigirDatas() async {
    if (!await _prontoPraManutencao()) return;
    final itens = _itensEnviados();
    final r = await _comProgresso('Corrigindo datas no Drive',
        (p, c) => BackupService.corrigirDatas(_gsi, itens,
            progresso: p, cancelado: c));
    if (!mounted) return;
    if (r == null) {
      _avisar('Não consegui ler o Drive (internet?). Nada foi mexido.');
      return;
    }
    final (ok, falhas, _) = r;
    _ev('Corrigir datas: $ok corrigidos, $falhas falhas, ${itens.length} conferidos');
    _avisar(ok == 0 && falhas == 0
        ? 'As datas no Drive já estão certas.'
        : '${_milhar(ok)} arquivos ficaram com a data original no Drive.'
            '${falhas > 0 ? ' ${_milhar(falhas)} não deu; tente de novo depois.' : ''}');
  }
}
