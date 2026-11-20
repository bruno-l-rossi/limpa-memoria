part of 'main.dart';

// Rodada 18: saiu do main.dart (achado A-32).

class MediaItem {
  final AssetEntity asset;
  int bytes;
  final String pasta;
  String path; // caminho real no disco (MediaStore); vazio se não veio
  final String caminhoRel; // relativePath completo (sugestões)
  MediaItem(this.asset, this.bytes, this.pasta,
      {this.path = '', this.caminhoRel = ''});

  bool get video => asset.type == AssetType.video;

  String get id => asset.id;
  String get titulo => asset.title ?? 'sem nome';

  /// Data da mídia (ms). Vai pro Drive como data do arquivo.
  int get data {
    try {
      return asset.createDateTime.millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }

  ItemBackup paraBackup() =>
      ItemBackup(id, titulo, pasta, path: path, bytes: bytes, data: data);
}
class Pasta {
  final String nome;
  final List<MediaItem> itens;
  int bytes = 0; // soma cacheada (antes era recalculada a cada leitura)
  Pasta(this.nome, this.itens) {
    recalcular();
  }
  void recalcular() => bytes = itens.fold(0, (s, i) => s + i.bytes);
}
List<Pasta> _agruparPastas(List<MediaItem> items) {
  final Map<String, List<MediaItem>> grupos = {};
  for (final it in items) {
    grupos.putIfAbsent(it.pasta, () => []).add(it);
  }
  return grupos.entries.map((e) => Pasta(e.key, e.value)).toList()
    ..sort((a, b) => b.bytes.compareTo(a.bytes));
}
/// Cache LRU de miniaturas em memória. O mesmo Uint8List reaproveitado faz o
/// Flutter reaproveitar também a imagem decodificada, então o scroll na grade
/// de milhares de itens deixa de re-decodificar a cada rebuild.
/// Rodada 11: o pedido da miniatura é cancelável. Scroll rápido por 30 mil
/// itens criava centenas de pedidos de células que já tinham saído da tela.
class _ThumbCache {
  static final Map<String, Uint8List> _mapa = {};
  static const _max = 600;

  static Uint8List? pegar(String id) {
    final v = _mapa.remove(id);
    if (v != null) _mapa[id] = v; // reinsere no fim (mais recente)
    return v;
  }

  static void guardar(String id, Uint8List bytes) {
    if (_mapa.length >= _max) _mapa.remove(_mapa.keys.first);
    _mapa[id] = bytes;
  }

  static Future<Uint8List?> carregar(
      AssetEntity asset, PMCancelToken token, int lado) {
    final id = asset.id;
    return asset
        .thumbnailDataWithSize(ThumbnailSize(lado, lado),
            quality: 80, cancelToken: token)
        .then((b) {
      if (b != null) guardar(id, b);
      return b;
    }).catchError((_) => null);
  }
}
/// Célula da grade: miniatura cacheada, badge de tamanho, nuvem quando já
/// subiu, círculo de seleção. Toque seleciona; segurar abre a prévia.
/// Grade de mídias com seleção por arrasto (rodada 18, achado A-26).
/// Sem nada selecionado, segurar abre a prévia (como antes). Com algo
/// selecionado, segurar e arrastar marca (ou desmarca) tudo no caminho, como
/// na galeria do Google.
class _GradeMidias extends StatefulWidget {
  final List<MediaItem> lista;
  final int lado;
  final bool Function(MediaItem) selecionado;
  final bool Function(MediaItem) noDrive;
  final String Function(MediaItem) tamanho;
  final bool Function() temSelecao;
  final void Function(MediaItem, bool) marcar;
  final void Function(MediaItem) aoTocar;
  final VoidCallback aoArrastar;
  final void Function(MediaItem) aoSegurar;
  const _GradeMidias({
    required this.lista,
    required this.lado,
    required this.selecionado,
    required this.noDrive,
    required this.tamanho,
    required this.temSelecao,
    required this.marcar,
    required this.aoTocar,
    required this.aoArrastar,
    required this.aoSegurar,
  });

  @override
  State<_GradeMidias> createState() => _GradeMidiasState();
}
class _GradeMidiasState extends State<_GradeMidias> {
  static const _colunas = 3;
  static const _espaco = 4.0;
  static const _margem = 4.0;
  final _chave = GlobalKey();
  final _rolagem = ScrollController();

  // Arrasto em andamento: célula onde começou, o que fazer (marcar ou
  // desmarcar), faixa já tocada e como estava antes (pra desfazer quando o
  // dedo volta).
  int? _inicio;
  bool _alvo = true;
  int _lo = 0, _hi = -1;
  final Map<int, bool> _antes = {};

  @override
  void dispose() {
    _rolagem.dispose();
    super.dispose();
  }

  int? _indiceEm(Offset global) {
    final box = _chave.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final p = box.globalToLocal(global);
    final largura = box.size.width;
    final lado = (largura - 2 * _margem - (_colunas - 1) * _espaco) / _colunas;
    if (lado <= 0) return null;
    final x = (p.dx - _margem).clamp(0.0, largura - 2 * _margem - 1);
    final y = p.dy + _rolagem.offset;
    final col = (x / (lado + _espaco)).floor().clamp(0, _colunas - 1);
    final lin = (y / (lado + _espaco)).floor();
    if (lin < 0) return 0;
    return (lin * _colunas + col).clamp(0, widget.lista.length - 1);
  }

  void _comecar(int i) {
    if (!widget.temSelecao()) {
      widget.aoSegurar(widget.lista[i]);
      return;
    }
    _inicio = i;
    _alvo = !widget.selecionado(widget.lista[i]);
    _antes.clear();
    _lo = i;
    _hi = i;
    _aplicar(i);
  }

  void _aplicar(int atual) {
    final ini = _inicio;
    if (ini == null) return;
    final a = ini < atual ? ini : atual, b = ini < atual ? atual : ini;
    if (a < _lo) _lo = a;
    if (b > _hi) _hi = b;
    var mudou = false;
    for (var k = _lo; k <= _hi; k++) {
      final m = widget.lista[k];
      _antes.putIfAbsent(k, () => widget.selecionado(m));
      final quer = (k >= a && k <= b) ? _alvo : _antes[k]!;
      if (widget.selecionado(m) != quer) {
        widget.marcar(m, quer);
        mudou = true;
      }
    }
    // Só redesenha quando o dedo entra numa célula nova (não a cada pixel).
    if (mudou) widget.aoArrastar();
  }

  void _mover(Offset global) {
    if (_inicio == null) return;
    // Perto da borda, rola a grade pra continuar marcando.
    final box = _chave.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && _rolagem.hasClients) {
      final y = box.globalToLocal(global).dy;
      final pos = _rolagem.position;
      if (y < 48) {
        _rolagem.jumpTo((pos.pixels - 24).clamp(0.0, pos.maxScrollExtent));
      } else if (y > box.size.height - 48) {
        _rolagem.jumpTo((pos.pixels + 24).clamp(0.0, pos.maxScrollExtent));
      }
    }
    final i = _indiceEm(global);
    if (i != null) _aplicar(i);
  }

  @override
  Widget build(BuildContext context) {
    _dependerDoTema(context);
    final lista = widget.lista;
    return GridView.builder(
      key: _chave,
      controller: _rolagem,
      padding: const EdgeInsets.fromLTRB(_margem, 0, _margem, _margem),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _colunas,
        mainAxisSpacing: _espaco,
        crossAxisSpacing: _espaco,
      ),
      itemCount: lista.length,
      itemBuilder: (context, i) {
        final item = lista[i];
        return _CelulaMidia(
          key: ValueKey(item.id),
          item: item,
          lado: widget.lado,
          selecionado: widget.selecionado(item),
          noDrive: widget.noDrive(item),
          tamanho: widget.tamanho(item),
          onTap: () => widget.aoTocar(item),
          onLongPressStart: (_) => _comecar(i),
          onLongPressMoveUpdate: (d) => _mover(d.globalPosition),
          onLongPressEnd: (_) {
            _inicio = null;
            _antes.clear();
          },
        );
      },
    );
  }
}
class _CelulaMidia extends StatelessWidget {
  final MediaItem item;
  final int lado;
  final bool selecionado;
  final bool noDrive;
  final String tamanho;
  final VoidCallback onTap;
  final GestureLongPressStartCallback onLongPressStart;
  final GestureLongPressMoveUpdateCallback onLongPressMoveUpdate;
  final GestureLongPressEndCallback onLongPressEnd;
  const _CelulaMidia({
    super.key,
    required this.item,
    required this.lado,
    required this.selecionado,
    required this.noDrive,
    required this.tamanho,
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressMoveUpdate,
    required this.onLongPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    _dependerDoTema(context);
    final isVideo = item.asset.type == AssetType.video;
    return Semantics(
      label:
          '${isVideo ? 'Vídeo' : 'Foto'} $tamanho${noDrive ? ', já no Drive' : ''}',
      selected: selecionado,
      button: true,
      child: GestureDetector(
      onTap: onTap,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      onLongPressEnd: onLongPressEnd,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Thumb(
              id: item.asset.id,
              asset: item.asset,
              isVideo: isVideo,
              lado: lado),
          if (selecionado)
            Container(color: _actionBlue.withValues(alpha: 0.28)),
          if (isVideo)
            const Center(
                child: Icon(Icons.play_circle_fill,
                    color: Colors.white70, size: 28)),
          Positioned(
            left: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(tamanho,
                  style: const TextStyle(color: Colors.white, fontSize: 11)),
            ),
          ),
          if (noDrive)
            const Positioned(
              left: 4,
              top: 4,
              child: Icon(Icons.cloud_done, color: Colors.white, size: 16),
            ),
          Positioned(
            right: 4,
            top: 4,
            child: Icon(
              selecionado ? Icons.check_circle : Icons.circle_outlined,
              color: selecionado ? _actionBlue : Colors.white70,
              size: 20,
            ),
          ),
        ],
      ),
      ),
    );
  }
}
/// Miniatura com cache LRU. Stateful: o pedido da miniatura nasce UMA vez
/// por célula (antes, cada rebuild da tela criava um pedido novo).
class _Thumb extends StatefulWidget {
  final String id;
  final AssetEntity asset;
  final bool isVideo;
  final int lado;
  const _Thumb(
      {required this.id,
      required this.asset,
      required this.isVideo,
      this.lado = 200});

  @override
  State<_Thumb> createState() => _ThumbState();
}
class _ThumbState extends State<_Thumb> {
  Uint8List? _bytes;
  Future<Uint8List?>? _fut;
  PMCancelToken? _token;
  bool _pronto = false;

  @override
  void initState() {
    super.initState();
    _iniciar();
  }

  @override
  void didUpdateWidget(covariant _Thumb old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _iniciar();
  }

  void _iniciar() {
    _cancelar();
    _bytes = _ThumbCache.pegar(widget.id);
    if (_bytes != null) {
      _fut = null;
      return;
    }
    final token = PMCancelToken();
    _token = token;
    _pronto = false;
    _fut = _ThumbCache.carregar(widget.asset, token, widget.lado)
        .whenComplete(() => _pronto = true);
  }

  void _cancelar() {
    final tk = _token;
    if (tk != null && !_pronto) tk.cancelRequest();
    _token = null;
  }

  @override
  void dispose() {
    _cancelar(); // saiu da tela antes de carregar: o Android para de gerar
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _dependerDoTema(context);
    final pronto = _bytes;
    if (pronto != null) {
      return Image.memory(pronto, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return FutureBuilder<Uint8List?>(
      future: _fut,
      builder: (c, snap) {
        final b = snap.data;
        if (b == null) {
          return Container(
            color: Colors.black12,
            child: Icon(widget.isVideo ? Icons.videocam : Icons.image,
                color: _inkMuted),
          );
        }
        return Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}
