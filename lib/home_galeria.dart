part of 'main.dart';

// Rodada 18: saiu do main.dart (achado A-32).
// Galeria: leitura das mídias, tamanhos, ordenação, filtros e seleção.

extension _Galeria on _HomePageState {
  /// Relê a galeria (fotos novas, acesso liberado). A seleção é limpa porque
  /// os itens são recriados.
  Future<void> _recarregarGaleria() async {
    if (_recarregando || _subindoAgora) return;
    _recarregando = true;
    try {
      _set(() {
        _selected.clear();
        _status = 'Recarregando galeria…';
      });
      await _load();
    } finally {
      _recarregando = false;
    }
  }
  Future<void> _load() async {
    final ps = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.common,
          // Sem isto o Android entrega as fotos sem a localização (EXIF GPS):
          // o backup perderia o "onde" de cada foto antes do original sumir.
          mediaLocation: true,
        ),
      ),
    );
    if (!ps.isAuth && !ps.hasAccess) {
      _set(() {
        _loading = false;
        _permissaoNegada = true;
      });
      return;
    }
    if (_permissaoNegada) _set(() => _permissaoNegada = false);
    _acessoTotal = ps.isAuth;
    _acessoParcial = !ps.isAuth && ps.hasAccess;
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
    );
    if (paths.isEmpty) {
      _set(() {
        _loading = false;
        _status = 'Nenhuma mídia encontrada.';
      });
      _galeriaPronta = true;
      _tentarRetomar();
      return;
    }
    final all = paths.first;
    final count = await all.assetCountAsync;

    // Rodada 19 (A-15): a galeria inteira numa consulta nativa só (< 1 s com
    // 30 mil itens), sem paginar pelo photo_manager. Se vier vazia ou com bem
    // menos itens que o photo_manager conta, cai no caminho antigo abaixo.
    final cron = Stopwatch()..start();
    final nativa = await Nativo.galeria();
    if (nativa != null && nativa.isNotEmpty && nativa.length >= count * 0.9) {
      final items = [
        for (final g in nativa)
          MediaItem(
            AssetEntity(
              id: g.id,
              typeInt: g.tipo,
              width: g.largura,
              height: g.altura,
              duration: g.duracaoSeg,
              orientation: g.orientacao,
              title: g.nome,
              createDateSecond: g.dataSeg,
              modifiedDateSecond: g.modSeg,
              relativePath: g.caminhoRel,
              mimeType: g.mime,
            ),
            g.bytes,
            nomePastaDrive(g.caminhoRel ?? ''),
            path: g.caminho,
            caminhoRel: g.caminhoRel ?? '',
          )
      ];
      _ev('Galeria nativa: ${items.length} itens em ${cron.elapsedMilliseconds} ms (photo_manager conta $count)');
      await _terminarCarga(items);
      return;
    }
    _ev('Galeria nativa recusada (${nativa?.length ?? 'erro'} de $count): paginando pelo photo_manager');

    // Consulta nativa em paralelo com a paginação (roda em thread própria).
    final infoFut = Nativo.midias();

    // 1ª página pequena (tela aparece rápido), depois páginas grandes
    // (menos idas e voltas ao Android).
    final List<MediaItem> items = [];
    for (var inicio = 0; inicio < count;) {
      final pagina = inicio == 0 ? 500 : 2000;
      final fim = min(inicio + pagina, count);
      final assets = await all.getAssetListRange(start: inicio, end: fim);
      final primeira = inicio == 0;
      inicio = fim;
      items.addAll([
        for (final a in assets)
          MediaItem(a, 0, _nomePasta(a), caminhoRel: a.relativePath ?? '')
      ]);
      if (primeira && mounted) {
        _set(() {
          _loading = false;
          _items = List.of(items);
          _calculando = true; // ainda paginando/medindo; o setState final corrige
          _lidos = 0;
          _status = 'Carregando galeria…';
          _ordenadoCache = null;
          _mudou();
        });
      }
    }

    final midiaInfo = await infoFut;
    for (final it in items) {
      final info = midiaInfo[it.id];
      if (info != null) {
        if (info.bytes > 0) it.bytes = info.bytes;
        it.path = info.caminho;
      }
    }
    _ev('Galeria paginada: ${items.length} itens em ${cron.elapsedMilliseconds} ms');
    await _terminarCarga(items);
  }

  /// Fecha a carga da galeria (dos 2 caminhos): tamanho do cache pra quem
  /// veio sem, pastas, totais e retomada.
  Future<void> _terminarCarga(List<MediaItem> items) async {
    final cacheFallback = await _store.tamanhos();
    for (final it in items) {
      if (it.bytes == 0) {
        final c = cacheFallback[it.id];
        if (c != null) it.bytes = c;
      }
    }
    final pastas = _agruparPastas(items);
    final faltam = items.where((it) => it.bytes == 0).length;
    if (!mounted) return;
    _set(() {
      _loading = false;
      _items = items;
      _pastas = pastas;
      _status = '${_milhar(items.length)} arquivos';
      _ordenadoCache = null;
      _filtradoCache = null;
      _bytesNoCelular = items.fold(0, (s, m) => s + m.bytes);
      _calculando = faltam > 0;
      _lidos = items.length - faltam;
      _mudou();
    });
    _galeriaPronta = true;
    _tentarRetomar();
    if (faltam > 0) _calcularTamanhosFallback();
  }
  Future<void> _calcularTamanhosFallback() async {
    final pendentes = _items.where((it) => it.bytes == 0).toList();
    final base = _items.length - pendentes.length;
    final novos = <String, int>{};
    for (var i = 0; i < pendentes.length; i++) {
      final it = pendentes[i];
      var b = 0;
      // 1º o caminho real (só lê o tamanho, não copia nada).
      if (it.path.isNotEmpty) {
        try {
          b = await File(it.path).length();
        } catch (_) {}
      }
      if (b == 0) {
        try {
          final f = await it.asset.originFile
              .timeout(const Duration(seconds: 60), onTimeout: () => null);
          b = f != null ? await f.length() : 0;
        } catch (_) {}
      }
      it.bytes = b;
      if (b > 0) novos[it.id] = b;
      if (i % 25 == 0) {
        if (mounted) _set(() => _lidos = base + i + 1);
        if (novos.length >= 1000) {
          await _store.salvarTamanhos(Map.of(novos));
          novos.clear();
        }
      }
    }
    if (novos.isNotEmpty) await _store.salvarTamanhos(novos);
    if (_emAndamento.isEmpty && _preparando.isEmpty) {
      try {
        await PhotoManager.clearFileCache();
      } catch (_) {}
    }
    if (!mounted) return;
    _set(() {
      _lidos = _items.length;
      _calculando = false;
      _ordenadoCache = null;
      _filtradoCache = null;
      _bytesNoCelular = _items.fold(0, (s, m) => s + m.bytes);
      for (final p in _pastas) {
        p.recalcular();
      }
      _selected.recalcular();
      _pastas.sort((a, b) => b.bytes.compareTo(a.bytes));
      _mudou();
    });
  }
  // Rodada 18: pai + pasta quando o pai não é raiz ("WhatsApp Images › Sent").
  String _nomePasta(AssetEntity a) => nomePastaDrive(a.relativePath ?? '');
  List<MediaItem> get _itensOrdenados {
    final ordemReal = (_ordem == 'data' || _calculando) ? 'data' : 'tamanho';
    final chave = '$ordemReal|${_items.length}|${identityHashCode(_items)}';
    if (_ordenadoCache != null && _ordenadoChave == chave) {
      return _ordenadoCache!;
    }
    final lista = List<MediaItem>.from(_items);
    if (ordemReal == 'data') {
      lista.sort(
          (x, y) => y.asset.createDateTime.compareTo(x.asset.createDateTime));
    } else {
      lista.sort((x, y) => y.bytes.compareTo(x.bytes));
    }
    _ordenadoCache = lista;
    _ordenadoChave = chave;
    _filtradoCache = null;
    return lista;
  }
  List<MediaItem> get _itensFiltrados {
    final base = _itensOrdenados;
    if (_filtro == 'todos' && _tipo == 'todos') return base;
    final chave = '$_filtro|$_tipo|$_rev|$_ordenadoChave';
    if (_filtradoCache != null && _filtradoChave == chave) {
      return _filtradoCache!;
    }
    final noDrive = _filtro == 'drive';
    final lista = base
        .where((m) =>
            (_filtro == 'todos' || _enviadosIds.contains(m.id) == noDrive) &&
            (_tipo == 'todos' || m.video == (_tipo == 'videos')))
        .toList(growable: false);
    _filtradoCache = lista;
    _filtradoChave = chave;
    return lista;
  }
  int get _totalSelecionado => _selected.bytes;
  void _toggle(MediaItem item) => _set(() {
        if (_selected.contains(item)) {
          _selected.remove(item);
        } else {
          _selected.add(item);
        }
      });
  /// Seleciona o que está VISÍVEL (respeita os filtros). Antes, com "Fora do
  /// Drive" ativo, marcava também o que já estava no Drive.
  void _selecionarTudo() => _set(() => _selected.addAll(_itensFiltrados));
  void _limparSelecao() => _set(() => _selected.clear());
  /// true = toda selecionada, false = nada, null = parte.
  bool? _estadoPasta(Pasta p) {
    final n = _selected.noGrupo(p.nome);
    if (n == 0) return false;
    return n == p.itens.length ? true : null;
  }
  void _togglePasta(Pasta p, bool? v) => _set(() {
        if (v == true) {
          _selected.addAll(p.itens);
        } else {
          _selected.removeAll(p.itens);
        }
      });
}
