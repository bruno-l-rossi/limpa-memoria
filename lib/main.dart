import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'dart:io';
import 'package:video_player/video_player.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:google_fonts/google_fonts.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';

void main() => runApp(const MyApp());

const Color _actionBlue = Color(0xFF0066CC);
const Color _ink = Color(0xFF1D1D1F);
const Color _inkMuted = Color(0xFF7A7A7A);
const Color _canvas = Color(0xFFFFFFFF);
const Color _parchment = Color(0xFFF5F5F7);
const Color _hairline = Color(0xFFE0E0E0);

ThemeData _tema() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _actionBlue,
    primary: _actionBlue,
    brightness: Brightness.light,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: _canvas,
    textTheme: GoogleFonts.interTextTheme(base.textTheme)
        .apply(bodyColor: _ink, displayColor: _ink),
    appBarTheme: AppBarTheme(
      backgroundColor: _canvas,
      foregroundColor: _ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: GoogleFonts.inter(
          color: _ink,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: _actionBlue,
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        textStyle: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w400),
      ),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Limpa Memória',
        debugShowCheckedModeBanner: false,
        theme: _tema(),
        home: const HomePage(),
      );
}

class MediaItem {
  final AssetEntity asset;
  int bytes;
  final String pasta;
  MediaItem(this.asset, this.bytes, this.pasta);
}

class Pasta {
  final String nome;
  final List<MediaItem> itens;
  Pasta(this.nome, this.itens);
  int get bytes => itens.fold(0, (s, i) => s + i.bytes);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _loading = true;
  String _status = 'Carregando...';
  List<MediaItem> _items = [];
  List<Pasta> _pastas = [];
  final Set<MediaItem> _selected = {};
  String _ordem = 'tamanho'; // 'tamanho' ou 'data'

  bool _calculando = false;
  int _lidos = 0;

  final GoogleSignIn _gsi = GoogleSignIn(
    scopes: ['https://www.googleapis.com/auth/drive.file'],
  );
  GoogleSignInAccount? _conta;

  final Set<MediaItem> _enviados = {};

  Widget _barraAcoes() {
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          TextButton.icon(
              onPressed: _selecionarTudo,
              icon: const Icon(Icons.done_all),
              label: const Text('Selecionar tudo')),
          TextButton(
              onPressed: _selected.isEmpty ? null : _limparSelecao,
              child: const Text('Limpar seleção')),
          const Spacer(),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            tooltip: 'Ordenar',
            onSelected: (v) => setState(() => _ordem = v),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                  value: 'tamanho',
                  checked: _ordem == 'tamanho',
                  child: const Text('Por tamanho')),
              CheckedPopupMenuItem(
                  value: 'data',
                  checked: _ordem == 'data',
                  child: const Text('Por data')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _login() async {
    try {
      final conta = await _gsi.signIn();
      setState(() => _conta = conta);
      if (conta != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Conectado como ${conta.email}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Falha no login: $e')));
      }
    }
  }

  Future<void> _logout() async {
    await _gsi.signOut();
    setState(() => _conta = null);
  }

  Future<void> _checarEspaco() async {
    final client = await _gsi.authenticatedClient();
    if (client == null) return;
    final api = drive.DriveApi(client);
    final about = await api.about.get($fields: 'storageQuota');
    final q = about.storageQuota;
    final usado = int.tryParse(q?.usage ?? '0') ?? 0;
    final limite = int.tryParse(q?.limit ?? '0') ?? 0;
    final msg = limite == 0
        ? 'Usado: ${_fmt(usado)} (conta sem limite definido)'
        : 'Livre: ${_fmt(limite - usado)} de ${_fmt(limite)}';
    if (mounted) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Espaço no Drive'),
          content: Text(msg),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK')),
          ],
        ),
      );
    }
  }

  Future<String> _acharOuCriarPasta(
      drive.DriveApi api, String nome, String? parentId) async {
    final nomeEsc = nome.replaceAll("'", r"\'");
    var q =
        "mimeType='application/vnd.google-apps.folder' and name='$nomeEsc' and trashed=false";
    if (parentId != null) q += " and '$parentId' in parents";
    final res = await api.files.list(q: q, $fields: 'files(id,name)');
    if (res.files != null && res.files!.isNotEmpty) {
      return res.files!.first.id!;
    }
    final nova = drive.File()
      ..name = nome
      ..mimeType = 'application/vnd.google-apps.folder';
    if (parentId != null) nova.parents = [parentId];
    final criada = await api.files.create(nova);
    return criada.id!;
  }

  Future<void> _subir() async {
    if (_conta == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Entre com o Google primeiro.')));
      return;
    }
    final client = await _gsi.authenticatedClient();
    if (client == null) return;
    final api = drive.DriveApi(client);

    final about = await api.about.get($fields: 'storageQuota');
    final usado = int.tryParse(about.storageQuota?.usage ?? '0') ?? 0;
    final limite = int.tryParse(about.storageQuota?.limit ?? '0') ?? 0;
    final livre = limite == 0 ? null : limite - usado;
    if (livre != null && _totalSelecionado > livre) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Não cabe. Precisa de ${_fmt(_totalSelecionado)}, livre ${_fmt(livre)}.')));
      return;
    }

    final selecionados = _selected.toList();
    final List<MediaItem> ok = [];
    final List<String> falhas = [];
    final progresso = ValueNotifier<double>(0);
    final textoProg = ValueNotifier<String>('Preparando...');

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Subindo para o Drive'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: textoProg,
              builder: (_, t, __) => Text(t),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<double>(
              valueListenable: progresso,
              builder: (_, p, __) => LinearProgressIndicator(value: p),
            ),
          ],
        ),
      ),
    );

    try {
      final mainId = await _acharOuCriarPasta(api, 'Limpa Memória', null);
      final Map<String, String> subCache = {};
      for (var i = 0; i < selecionados.length; i++) {
        final item = selecionados[i];
        textoProg.value = 'Subindo ${i + 1} de ${selecionados.length}...';
        try {
          var subId = subCache[item.pasta];
          if (subId == null) {
            subId = await _acharOuCriarPasta(api, item.pasta, mainId);
            subCache[item.pasta] = subId;
          }
          final f = await item.asset.file;
          if (f == null) {
            falhas.add(item.asset.title ?? 'sem nome');
          } else {
            final media = drive.Media(f.openRead(), await f.length());
            final meta = drive.File()
              ..name = item.asset.title
              ..parents = [subId];
            await api.files.create(meta, uploadMedia: media);
            ok.add(item);
          }
        } catch (e) {
          falhas.add(item.asset.title ?? 'sem nome');
        }
        progresso.value = (i + 1) / selecionados.length;
      }
    } finally {
      _enviados.addAll(ok);
      if (mounted) Navigator.of(context).pop();
      setState(() {});
    }

    if (!mounted) return;
    if (ok.isNotEmpty) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Backup concluído'),
          content: Text(
              '${ok.length} de ${selecionados.length} arquivos salvos no Drive na pasta Limpa Memória. Apagar do celular para liberar espaço?'
              '${falhas.isEmpty ? '' : '\n\nFalharam: ${falhas.join(', ')}'}'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Agora não')),
            FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  _apagarEnviados();
                },
                child: const Text('Apagar do celular')),
          ],
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Nada subiu'),
          content: Text('Falharam: ${falhas.join(', ')}'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK')),
          ],
        ),
      );
    }
  }

  Future<void> _apagarEnviados() async {
    if (_enviados.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nada confirmado no Drive. Suba antes de apagar.')));
      return;
    }
    final lista = _enviados.toList();
    final ids = lista.map((m) => m.asset.id).toList();
    final apagados = await PhotoManager.editor.deleteWithIds(ids);
    final setApagados = apagados.toSet();
    setState(() {
      _items.removeWhere((m) => setApagados.contains(m.asset.id));
      _enviados.removeWhere((m) => setApagados.contains(m.asset.id));
      _selected.removeWhere((m) => setApagados.contains(m.asset.id));
      final Map<String, List<MediaItem>> grupos = {};
      for (final it in _items) {
        grupos.putIfAbsent(it.pasta, () => []).add(it);
      }
      _pastas = grupos.entries.map((e) => Pasta(e.key, e.value)).toList()
        ..sort((a, b) => b.bytes.compareTo(a.bytes));
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Apagados ${apagados.length} do celular.')));
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth && !ps.hasAccess) {
      setState(() {
        _loading = false;
        _status = 'Permissão negada. Libere o acesso a fotos e tente de novo.';
      });
      return;
    }
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
    );
    if (paths.isEmpty) {
      setState(() {
        _loading = false;
        _status = 'Nenhuma mídia encontrada.';
      });
      return;
    }
    final all = paths.first;
    final count = await all.assetCountAsync;
    final assets = await all.getAssetListRange(start: 0, end: count);
    final List<MediaItem> items = [
      for (final a in assets) MediaItem(a, 0, _nomePasta(a))
    ];
    final Map<String, List<MediaItem>> grupos = {};
    for (final it in items) {
      grupos.putIfAbsent(it.pasta, () => []).add(it);
    }
    final pastas = grupos.entries.map((e) => Pasta(e.key, e.value)).toList();
    setState(() {
      _loading = false;
      _items = items;
      _pastas = pastas;
      _status = '${items.length} arquivos';
      _calculando = true;
      _lidos = 0;
    });
    _calcularTamanhos();
  }

  Future<void> _calcularTamanhos() async {
    for (var i = 0; i < _items.length; i++) {
      try {
        final f = await _items[i].asset.file;
        _items[i].bytes = f != null ? await f.length() : 0;
      } catch (_) {
        _items[i].bytes = 0;
      }
      if (i % 25 == 0 && mounted) {
        setState(() => _lidos = i + 1);
      }
    }
    if (!mounted) return;
    setState(() {
      _lidos = _items.length;
      _calculando = false;
      _pastas.sort((a, b) => b.bytes.compareTo(a.bytes));
    });
  }

  String _nomePasta(AssetEntity a) {
    final rp = a.relativePath ?? '';
    final partes = rp.split('/').where((p) => p.isNotEmpty).toList();
    return partes.isEmpty ? 'Outros' : partes.last;
  }

  List<MediaItem> get _itensOrdenados {
    final lista = List<MediaItem>.from(_items);
    if (_ordem == 'data' || _calculando) {
      lista.sort(
          (x, y) => y.asset.createDateTime.compareTo(x.asset.createDateTime));
    } else {
      lista.sort((x, y) => y.bytes.compareTo(x.bytes));
    }
    return lista;
  }

  String _fmt(int bytes) {
    if (bytes <= 0) return '0 MB';
    const u = ['B', 'KB', 'MB', 'GB', 'TB'];
    double v = bytes.toDouble();
    int i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    final txt = i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '${txt.replaceAll('.', ',')} ${u[i]}';
  }
  int get _totalSelecionado => _selected.fold(0, (s, i) => s + i.bytes);

  void _toggle(MediaItem item, bool? v) => setState(() {
        if (v == true) {
          _selected.add(item);
        } else {
          _selected.remove(item);
        }
      });

  void _selecionarTudo() => setState(() => _selected.addAll(_items));
  void _limparSelecao() => setState(() => _selected.clear());
  bool _pastaToda(Pasta p) => p.itens.every(_selected.contains);

  void _togglePasta(Pasta p, bool? v) => setState(() {
        if (v == true) {
          _selected.addAll(p.itens);
        } else {
          _selected.removeAll(p.itens);
        }
      });

  void _continuar() {
    final nomes = _selected.map((m) => m.asset.title ?? 'sem nome').join('\n');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${_selected.length} arquivos, ${_fmt(_totalSelecionado)}'),
        content: Text(nomes.isEmpty ? 'Nada marcado.' : nomes),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Limpa Memória'),
          bottom: const TabBar(
            labelColor: _ink,
            unselectedLabelColor: _inkMuted,
            indicatorColor: _actionBlue,
            tabs: [Tab(text: 'Mídias'), Tab(text: 'Pastas')],
          ),
          actions: [
            IconButton(
              icon: Icon(_conta == null
                  ? Icons.account_circle_outlined
                  : Icons.account_circle),
              tooltip: _conta?.email ?? 'Entrar com Google',
              onPressed: _conta == null ? _login : _logout,
            ),
            IconButton(
              icon: const Icon(Icons.cloud_queue),
              tooltip: 'Espaço no Drive',
              onPressed: _conta == null ? null : _checarEspaco,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Apagar do celular (so os que ja subiram)',
              onPressed: _enviados.isEmpty ? null : _apagarEnviados,
            ),
          ],
        ),
        body: _loading || _items.isEmpty
            ? Center(child: Text(_status))
            : Column(
                children: [
                  if (_calculando) ...[
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          minHeight: 6,
                          backgroundColor: _hairline,
                          value: _items.isEmpty ? null : _lidos / _items.length,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text(
                        '${_items.isEmpty ? 0 : _lidos * 100 ~/ _items.length}% das mídias lidas',
                        style: const TextStyle(color: _inkMuted, fontSize: 14),
                      ),
                    ),
                  ] else
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text('Todas as mídias lidas com sucesso',
                          style: TextStyle(color: _inkMuted, fontSize: 14)),
                    ),
                  Expanded(
                    child: TabBarView(children: [_abaMidias(), _abaPastas()]),
                  ),
                ],
              ),
        bottomNavigationBar: _items.isEmpty
            ? null
            : Container(
                decoration: const BoxDecoration(
                  color: _parchment,
                  border: Border(top: BorderSide(color: _hairline)),
                ),
                child: SafeArea(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(
                            child: Text(
                                '${_selected.length} selecionados • ${_fmt(_totalSelecionado)}')),
                        FilledButton(
                            onPressed: _selected.isEmpty ? null : _subir,
                            child: const Text('Subir')),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _abaMidias() {
    final lista = _itensOrdenados;
    return Column(
      children: [
        _barraAcoes(),
        Expanded(
          child: ListView.builder(
            itemCount: lista.length,
            itemBuilder: (context, i) {
              final item = lista[i];
              final isVideo = item.asset.type == AssetType.video;
              return ListTile(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => PreviewPage(item.asset))),
                leading: _Miniatura(asset: item.asset, isVideo: isVideo),
                title: Text(item.asset.title ?? 'sem nome'),
                subtitle: Text('${item.pasta} • ${_fmt(item.bytes)}'),
                trailing: Checkbox(
                    value: _selected.contains(item),
                    onChanged: (v) => _toggle(item, v)),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _abaPastas() {
    return Column(
      children: [
        _barraAcoes(),
        Expanded(
          child: ListView.builder(
            itemCount: _pastas.length,
            itemBuilder: (context, i) {
              final p = _pastas[i];
              return CheckboxListTile(
                value: _pastaToda(p),
                onChanged: (v) => _togglePasta(p, v),
                title: Text(p.nome),
                subtitle:
                    Text('${p.itens.length} arquivos • ${_fmt(p.bytes)}'),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Miniatura extends StatelessWidget {
  final AssetEntity asset;
  final bool isVideo;
  const _Miniatura({required this.asset, required this.isVideo});
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailDataWithSize(const ThumbnailSize(120, 120)),
      builder: (c, snap) {
        if (snap.data == null) {
          return Container(
            width: 52,
            height: 52,
            color: Colors.black12,
            child: Icon(isVideo ? Icons.videocam : Icons.image),
          );
        }
        return Stack(
          alignment: Alignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(snap.data!,
                  width: 52, height: 52, fit: BoxFit.cover),
            ),
            if (isVideo)
              const Icon(Icons.play_circle_fill, color: Colors.white, size: 22),
          ],
        );
      },
    );
  }
}

class PreviewPage extends StatefulWidget {
  final AssetEntity asset;
  const PreviewPage(this.asset, {super.key});
  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  VideoPlayerController? _video;
  Uint8List? _imagem;
  bool _carregando = true;
  bool get _isVideo => widget.asset.type == AssetType.video;

  @override
  void initState() {
    super.initState();
    _preparar();
  }

  Future<void> _preparar() async {
    if (_isVideo) {
      final f = await widget.asset.file;
      if (f != null) {
        final c = VideoPlayerController.file(f);
        await c.initialize();
        await c.setLooping(true);
        await c.play();
        if (mounted) setState(() { _video = c; _carregando = false; });
        return;
      }
    } else {
      final bytes = await widget.asset.originBytes;
      if (mounted) setState(() { _imagem = bytes; _carregando = false; });
      return;
    }
    if (mounted) setState(() => _carregando = false);
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget corpo;
    if (_carregando) {
      corpo = const CircularProgressIndicator();
    } else if (_isVideo && _video != null) {
      final ar = _video!.value.aspectRatio;
      corpo = AspectRatio(
        aspectRatio: ar == 0 ? 16 / 9 : ar,
        child: VideoPlayer(_video!),
      );
    } else if (!_isVideo && _imagem != null) {
      corpo = Image.memory(_imagem!);
    } else {
      corpo = const Text('Não deu pra abrir',
          style: TextStyle(color: Colors.white));
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.asset.title ?? 'Prévia')),
      backgroundColor: Colors.black,
      body: Center(child: corpo),
      floatingActionButton: (_isVideo && _video != null)
          ? FloatingActionButton(
              onPressed: () => setState(() {
                _video!.value.isPlaying ? _video!.pause() : _video!.play();
              }),
              child: Icon(
                  _video!.value.isPlaying ? Icons.pause : Icons.play_arrow),
            )
          : null,
    );
  }
}