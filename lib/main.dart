import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:google_fonts/google_fonts.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:background_downloader/background_downloader.dart';
import 'upload_store.dart';
import 'backup_service.dart';

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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
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

  // Backup em segundo plano.
  final UploadStore _store = UploadStore();
  Set<String> _enviadosIds = {}; // ids já confirmados no Drive
  final Set<String> _emFila = {}; // todos os ids deste backup (total da barra)
  int _falhasBg = 0; // uploads que falharam de vez
  String? _erroBg; // último motivo de erro, pra mostrar na tela
  StreamSubscription<TaskUpdate>? _sub;

  // Janela deslizante: poucos uploads ativos por vez, repondo conforme terminam.
  static const int _janela = 12; // máximo de uploads simultâneos
  final List<ItemBackup> _pendentes = []; // ainda não enfileirados
  final Set<String> _emAndamento = {}; // ids enfileirados/subindo agora
  final Map<String, int> _tentativas = {}; // re-tentativas por id
  bool _alimentando = false; // trava de reentrância

  int get _bgTotal => _emFila.length;
  int get _bgFeitos => _emFila.where(_enviadosIds.contains).length;

  /// Repõe a janela: enfileira o próximo pendente até ter _janela ativos.
  Future<void> _alimentarFila() async {
    if (_alimentando) return;
    _alimentando = true;
    try {
      while (_emAndamento.length < _janela && _pendentes.isNotEmpty) {
        final item = _pendentes.removeAt(0);
        if (_enviadosIds.contains(item.id) || _emAndamento.contains(item.id)) {
          continue; // já subiu ou já está na fila
        }
        _emAndamento.add(item.id);
        if (mounted) setState(() {});
        final (ok, erro) = await BackupService.enfileirarUm(_gsi, item);
        if (!ok) {
          _emAndamento.remove(item.id);
          final t = (_tentativas[item.id] ?? 0) + 1;
          _tentativas[item.id] = t;
          if (t <= 3) {
            _pendentes.add(item); // volta pro fim da fila
          } else if (mounted) {
            setState(() {
              _falhasBg++;
              if (erro != null && erro.isNotEmpty) _erroBg = erro;
            });
          }
        }
        if (mounted) setState(() {});
      }
    } finally {
      _alimentando = false;
    }
  }

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

  Future<void> _subir() async {
    if (_conta == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Entre com o Google primeiro.')));
      return;
    }

    // Só o que ainda não subiu (não re-sobe o que já está no Drive).
    final aSubir = _selected.where((m) => !_enviadosIds.contains(m.asset.id));
    final itens = aSubir
        .map((m) => ItemBackup(m.asset.id, m.asset.title ?? 'sem nome', m.pasta))
        .toList();
    if (itens.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Tudo que você marcou já está no Drive.')));
      return;
    }

    // Checa espaço (some os bytes do que ainda falta subir).
    final livre = await BackupService.espacoLivre(_gsi);
    final precisa = _selected
        .where((m) => !_enviadosIds.contains(m.asset.id))
        .fold<int>(0, (s, m) => s + m.bytes);
    if (livre != null && precisa > livre) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Não cabe. Precisa de ${_fmt(precisa)}, livre ${_fmt(livre)}.')));
      return;
    }

    // Prepara o contexto (token + pasta principal) antes de alimentar a janela.
    final (ok, erroCtx) = await BackupService.prepararContexto(_gsi);
    if (!ok) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Não consegui começar o backup'),
          content: Text(erroCtx ?? 'Falha ao preparar o Drive.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK')),
          ],
        ),
      );
      return;
    }

    await _store.salvarJob(itens.map((e) => e.toMap()).toList());

    if (mounted) {
      setState(() {
        _falhasBg = 0;
        _erroBg = null;
        _tentativas.clear();
        // Total estável desde já: todos os selecionados.
        _emFila.addAll(itens.map((e) => e.id));
        // Enche a fila de pendentes; a janela vai puxando aos poucos.
        _pendentes
          ..clear()
          ..addAll(itens);
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Backup começou. Sobe aos poucos, pode fechar o app que continua sozinho.')));
    }

    _alimentarFila();
  }

  Future<void> _apagarEnviados() async {
    // Só apaga do celular o que está confirmado no Drive E ainda na lista.
    final idsNoCelular = _items.map((m) => m.asset.id).toSet();
    final ids = _enviadosIds.where(idsNoCelular.contains).toList();
    if (ids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nada confirmado no Drive. Suba antes de apagar.')));
      return;
    }
    final apagados = await PhotoManager.editor.deleteWithIds(ids);
    final setApagados = apagados.toSet();
    await _store.esquecerEnviados(setApagados);
    setState(() {
      _items.removeWhere((m) => setApagados.contains(m.asset.id));
      _enviadosIds.removeAll(setApagados);
      _selected.removeWhere((m) => setApagados.contains(m.asset.id));
      _emFila.removeAll(setApagados);
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
    WidgetsBinding.instance.addObserver(this);
    _iniciarBackupEngine();
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _store.gravarAgora();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Indo pro fundo ou fechando: grava o progresso na hora, sem esperar o lote.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _store.gravarAgora();
    }
  }

  Future<void> _iniciarBackupEngine() async {
    await BackupService.configurar();
    // Listener PRIMEIRO: o iniciarMotor() abaixo reprocessa o que terminou em
    // segundo plano, e sem o listener no ar a gente perderia essas conclusões
    // (era a causa da contagem zerando).
    _sub = FileDownloader().updates.listen(_onUpdate);
    await BackupService.iniciarMotor();

    // Reconcilia com o banco da biblioteca PRIMEIRO: tudo que consta como
    // concluído (até o que subiu com o app fechado) entra nos enviados. Mantém a
    // contagem certa e impede re-subir o que já está no Drive (sem duplicata).
    final concluidos = await BackupService.concluidosNoBanco();
    for (final id in concluidos) {
      await _store.marcarEnviado(id);
    }
    await _store.gravarAgora();

    // Só depois de salvar o que já subiu: limpeza única da fila herdada das
    // builds antigas (que enfileiravam tudo de uma vez). Roda uma vez por versão.
    if (await _store.precisaLimparFila()) {
      await BackupService.limparFilaLegada();
      await _store.marcarFilaLimpa();
    }

    // Restaura o login da última vez (sem pedir nada), pra poder retomar sozinho.
    try {
      final conta = await _gsi.signInSilently();
      if (conta != null && mounted) setState(() => _conta = conta);
    } catch (_) {}

    final enviados = await _store.enviados();
    final job = await _store.job();
    if (mounted) {
      setState(() {
        _enviadosIds = enviados;
        if (job.isNotEmpty) {
          _emFila
            ..clear()
            ..addAll(job.map((m) => m['id'] ?? ''));
        }
      });
    }
    // Retoma sozinho na janela: o que o job pedia, menos o que já subiu e o que
    // o motor já tem ativo, vira pendente e a janela vai puxando.
    _retomarJanela(job);
  }

  // Cada arquivo que termina em segundo plano cai aqui, mesmo com a tela apagada.
  void _onUpdate(TaskUpdate update) async {
    if (update is! TaskStatusUpdate ||
        update.task.group != BackupService.grupo) {
      return;
    }
    final id = update.task.taskId;
    if (update.status == TaskStatus.complete) {
      await _store.marcarEnviado(id);
      _emAndamento.remove(id);
      _tentativas.remove(id);
      if (mounted) setState(() => _enviadosIds.add(id));
      _alimentarFila(); // repõe a janela com o próximo
    } else if (update.status == TaskStatus.failed ||
        update.status == TaskStatus.notFound) {
      _emAndamento.remove(id);
      final desc = update.exception?.description;
      final t = (_tentativas[id] ?? 0) + 1;
      _tentativas[id] = t;
      if (t <= 3 && _emFila.contains(id) && !_enviadosIds.contains(id)) {
        // Falhou mesmo depois das retentativas internas: tenta de novo com uma
        // sessão nova, no fim da fila.
        _pendentes.add(
            ItemBackup(id, update.task.filename, update.task.metaData));
      } else if (mounted) {
        setState(() {
          _falhasBg++;
          if (desc != null && desc.isNotEmpty) _erroBg = desc;
        });
      }
      if (mounted) setState(() {});
      _alimentarFila();
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _retomarJanela(List<Map<String, String>> job) async {
    if (job.isEmpty || _conta == null) return;
    // Espera o motor restaurar a fila nativa antes de decidir o que falta.
    await Future.delayed(const Duration(seconds: 3));
    final enviados = await _store.enviados(); // leitura fresca
    final ativos = await BackupService.idsAtivos(); // o que o motor já retomou
    if (!mounted) return;
    _emAndamento.addAll(ativos.where((id) => !enviados.contains(id)));
    final pendentes = job
        .where((m) {
          final id = m['id'] ?? '';
          return id.isNotEmpty &&
              !enviados.contains(id) &&
              !_emAndamento.contains(id);
        })
        .map(ItemBackup.fromMap)
        .toList();
    if (pendentes.isEmpty) {
      if (mounted) setState(() {});
      return;
    }
    final (ok, _) = await BackupService.prepararContexto(_gsi);
    if (!ok) return;
    if (!mounted) return;
    setState(() {
      _pendentes
        ..clear()
        ..addAll(pendentes);
    });
    _alimentarFila();
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
              onPressed: _enviadosIds.isEmpty ? null : _apagarEnviados,
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
                  _bannerBackup(),
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

  Widget _bannerBackup() {
    if (_emFila.isEmpty) return const SizedBox.shrink();
    final total = _bgTotal;
    final feitos = _bgFeitos;
    final pronto = feitos >= total;
    final pct = total == 0 ? 0.0 : feitos / total;
    return Container(
      width: double.infinity,
      color: _parchment,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(pronto ? Icons.cloud_done : Icons.cloud_upload,
                  size: 18, color: _actionBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  pronto
                      ? 'Backup concluído: $feitos arquivos no Drive'
                      : 'Subindo backup: $feitos de $total',
                  style: const TextStyle(fontSize: 14, color: _ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 6,
              backgroundColor: _hairline,
              value: pct,
            ),
          ),
          if (!pronto)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  'Subindo agora: ${_emAndamento.length} · na fila: ${_pendentes.length} · pode fechar o app',
                  style: const TextStyle(fontSize: 12, color: _inkMuted)),
            ),
          if (_falhasBg > 0 || _erroBg != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _erroBg != null
                    ? 'Problema: $_erroBg'
                    : '$_falhasBg arquivo(s) falharam.',
                style: const TextStyle(fontSize: 12, color: Color(0xFFB00020)),
              ),
            ),
        ],
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
              final jaSubiu = _enviadosIds.contains(item.asset.id);
              return ListTile(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => PreviewPage(item.asset))),
                leading: _Miniatura(asset: item.asset, isVideo: isVideo),
                title: Text(item.asset.title ?? 'sem nome'),
                subtitle: Text(jaSubiu
                    ? '${item.pasta} • ${_fmt(item.bytes)} • no Drive'
                    : '${item.pasta} • ${_fmt(item.bytes)}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (jaSubiu)
                      const Icon(Icons.cloud_done,
                          size: 18, color: _actionBlue),
                    Checkbox(
                        value: _selected.contains(item),
                        onChanged: (v) => _toggle(item, v)),
                  ],
                ),
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