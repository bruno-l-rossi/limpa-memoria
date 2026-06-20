import 'dart:async';
import 'dart:math';
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
  String _filtro = 'todos'; // 'todos' | 'drive' | 'foradrive'

  bool _calculando = false;
  int _lidos = 0;

  final GoogleSignIn _gsi = GoogleSignIn(
    scopes: ['https://www.googleapis.com/auth/drive.file'],
  );
  GoogleSignInAccount? _conta;

  // Backup em segundo plano.
  final UploadStore _store = UploadStore();
  Set<String> _enviadosIds = {}; // ids já confirmados no Drive
  final Set<String> _emFila = {}; // total estável da sessão (denominador da barra)
  int _falhasBg = 0; // uploads que falharam de vez
  String? _erroBg; // último motivo de erro, pra mostrar na tela
  bool _pausado = false; // backup pausado pelo usuário
  StreamSubscription<TaskUpdate>? _sub;

  // Janela deslizante guiada pelo banco da biblioteca (a fonte da verdade).
  static const int _janela = 6; // alguns por vez; preparo agora roda em paralelo
  final List<ItemBackup> _pendentes = []; // ainda não enfileirados
  final Set<String> _emAndamento = {}; // ativos no motor agora (só pra exibir)
  final Map<String, int> _tentativas = {}; // re-tentativas por id
  bool _sincronizando = false; // trava de reentrância
  Timer? _poll; // sincroniza com o banco a cada 15s

  int get _bgTotal => _emFila.length;
  int get _bgFeitos => _emFila.where(_enviadosIds.contains).length;

  /// Pergunta ao banco da biblioteca o que concluiu e o que está ativo, atualiza
  /// a contagem e repõe a janela. Chamado a cada 15s e quando algo termina. Não
  /// depende de capturar todo evento ao vivo (que pode se perder num job longo):
  /// o banco é a fonte da verdade, então a janela nunca congela de vez.
  ///
  /// O preparo de cada arquivo (achar pasta, abrir o arquivo, criar a sessão do
  /// Drive) agora roda em PARALELO numa leva só. Antes era um a um, em fila, e
  /// esse preparo serial era o gargalo: a banda ficava ociosa esperando o app
  /// preparar o próximo. Em paralelo a janela enche rápido e a rede trabalha.
  Future<void> _sincronizarEAlimentar() async {
    if (_sincronizando || _conta == null || _emFila.isEmpty) return;
    _sincronizando = true;
    try {
      final anterior = Set<String>.of(_emAndamento);
      // O que está ativo no motor agora (consulta barata, só os ativos).
      final ativos = (await BackupService.idsAtivos())
          .where((id) => !_enviadosIds.contains(id))
          .toSet();
      // Quem saiu da janela desde a última vez: confere por id (leitura barata)
      // se concluiu, e marca. Pega conclusões que o evento ao vivo perdeu.
      for (final id in anterior.difference(ativos)) {
        final st = await BackupService.statusDe(id);
        if (st == TaskStatus.complete && !_enviadosIds.contains(id)) {
          await _store.marcarEnviado(id);
          _enviadosIds.add(id);
        }
      }
      _emAndamento
        ..clear()
        ..addAll(ativos);

      // Pausado: só reconcilia o que terminou; não alimenta mais a janela.
      if (!_pausado) {
        final vagas = _janela - _emAndamento.length;
        final lote = <ItemBackup>[];
        while (lote.length < vagas && _pendentes.isNotEmpty) {
          final item = _pendentes.removeAt(0);
          if (_enviadosIds.contains(item.id) ||
              _emAndamento.contains(item.id) ||
              lote.any((e) => e.id == item.id)) {
            continue;
          }
          lote.add(item);
        }
        if (lote.isNotEmpty) {
          // Pré-cria as subpastas da leva ANTES do paralelo, senão dois uploads
          // da mesma pasta nova criariam a pasta duas vezes no Drive.
          await BackupService.garantirSubpastas(_gsi, lote.map((e) => e.pasta));
          final res = await Future.wait(lote.map((item) async {
            final (ok, erro) = await BackupService.enfileirarUm(_gsi, item);
            return (item: item, ok: ok, erro: erro);
          }));
          for (final r in res) {
            if (r.ok) {
              _emAndamento.add(r.item.id);
            } else {
              final t = (_tentativas[r.item.id] ?? 0) + 1;
              _tentativas[r.item.id] = t;
              if (t <= 3) {
                _pendentes.add(r.item); // volta pro fim da fila
              } else {
                _falhasBg++;
                if (r.erro != null && r.erro!.isNotEmpty) _erroBg = r.erro;
              }
            }
          }
        }
      }
      if (mounted) setState(() {});
    } catch (_) {
      // silencioso: tenta de novo no próximo ciclo de 15s
    } finally {
      _sincronizando = false;
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

    // Os selecionados viram itens. A sessão (job) é MESCLADA, nunca reescrita
    // menor: é o que faz o total da barra ficar estável do começo ao fim. Antes,
    // cada toque em Subir salvava só "o que ainda falta", então o denominador
    // caía (19000 -> 14000 -> 200). Se a sessão anterior já terminou, começa nova.
    final selecionados = _selected
        .map((m) => ItemBackup(m.asset.id, m.asset.title ?? 'sem nome', m.pasta))
        .toList();

    final jobAtual = await _store.job();
    final sessaoTerminou =
        _emFila.isNotEmpty && _emFila.every(_enviadosIds.contains);
    final Map<String, Map<String, String>> mapa = {};
    if (!sessaoTerminou) {
      for (final m in jobAtual) {
        final id = m['id'] ?? '';
        if (id.isNotEmpty) mapa[id] = m;
      }
    }
    for (final it in selecionados) {
      mapa[it.id] = it.toMap();
    }
    final mergedItens = mapa.values.map(ItemBackup.fromMap).toList();

    // O que ainda falta subir nesta sessão (não re-sobe o que já está no Drive).
    final pendentesItens =
        mergedItens.where((it) => !_enviadosIds.contains(it.id)).toList();
    if (pendentesItens.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Tudo que você marcou já está no Drive.')));
      return;
    }

    // Checa espaço (soma os bytes do que ainda falta subir).
    final idsPendentes = pendentesItens.map((e) => e.id).toSet();
    final precisa = _items
        .where((m) => idsPendentes.contains(m.asset.id))
        .fold<int>(0, (s, m) => s + m.bytes);
    final livre = await BackupService.espacoLivre(_gsi);
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

    await _store.salvarJob(mergedItens.map((e) => e.toMap()).toList());
    await _store.setPausado(false);

    if (mounted) {
      setState(() {
        _pausado = false;
        _falhasBg = 0;
        _erroBg = null;
        _tentativas.clear();
        // Total estável: todos os itens da sessão (mesclados).
        _emFila
          ..clear()
          ..addAll(mergedItens.map((e) => e.id));
        // Pendentes = o que falta; a janela vai puxando aos poucos.
        _pendentes
          ..clear()
          ..addAll(pendentesItens);
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Backup começou. Sobe aos poucos, pode fechar o app que continua sozinho.')));
    }

    _sincronizarEAlimentar();
  }

  /// Para o backup: deixa de alimentar a janela (o que já estava subindo termina
  /// sozinho) e limpa os pendentes. O job fica salvo, então o Retomar reconstrói
  /// o que falta a partir de job menos enviados, sem re-subir nada (sem duplicata).
  Future<void> _parar() async {
    await _store.setPausado(true);
    if (mounted) {
      setState(() {
        _pausado = true;
        _pendentes.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Backup pausado. O que já estava subindo termina; o resto fica guardado pra retomar.')));
    }
  }

  Future<void> _retomar() async {
    await _store.setPausado(false);
    if (mounted) setState(() => _pausado = false);
    final job = await _store.job();
    await _retomarJanela(job);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Retomando de onde parou.')));
    }
  }

  Future<void> _apagarEnviados() async {
    // Só apaga do celular o que está confirmado no Drive E ainda na lista.
    final idsNoCelular = _items.map((m) => m.asset.id).toSet();
    final ids = _enviadosIds.where(idsNoCelular.contains).toList();
    if (ids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nada confirmado no Drive ainda. Suba antes de apagar.')));
      return;
    }

    final bytes = _items
        .where((m) => ids.contains(m.asset.id))
        .fold<int>(0, (s, m) => s + m.bytes);
    final confirma = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Apagar do celular'),
        content: Text(
            'Apagar ${ids.length} arquivos (${_fmt(bytes)}) que já estão no Drive?\n\nO Android vai pedir confirmação em algumas levas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Apagar')),
        ],
      ),
    );
    if (confirma != true) return;

    // Apaga em LOTES. Mandar milhares de ids de uma vez estoura o limite do
    // Android (TransactionTooLargeException) e o clique não fazia nada. Em lotes
    // de 800 cada chamada cabe; o Android pede confirmação por lote.
    const tamLote = 800;
    final List<String> apagadosAll = [];
    for (var i = 0; i < ids.length; i += tamLote) {
      final chunk = ids.sublist(i, min(i + tamLote, ids.length));
      try {
        final apag = await PhotoManager.editor.deleteWithIds(chunk);
        apagadosAll.addAll(apag);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Parou em ${apagadosAll.length} apagados: $e')));
        }
        break;
      }
    }

    final setApagados = apagadosAll.toSet();
    await _store.esquecerEnviados(setApagados);
    if (!mounted) return;
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Apagados ${setApagados.length} do celular.')));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _iniciarBackupEngine();
    _load();
    // Rede de segurança: a cada 15s sincroniza com o banco e repõe a janela,
    // mesmo que algum evento ao vivo tenha se perdido.
    _poll = Timer.periodic(
        const Duration(seconds: 15), (_) => _sincronizarEAlimentar());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
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
    final pausado = await _store.pausado();
    if (mounted) {
      setState(() {
        _enviadosIds = enviados;
        _pausado = pausado;
        if (job.isNotEmpty) {
          _emFila
            ..clear()
            ..addAll(job.map((m) => m['id'] ?? ''));
        }
      });
    }
    // Retoma sozinho na janela (a não ser que o usuário tenha deixado pausado):
    // o que o job pedia, menos o que já subiu, vira pendente e a janela puxa.
    _retomarJanela(job);
  }

  // Resposta rápida a um evento ao vivo. A contagem e a janela de verdade são
  // mantidas pelo _sincronizarEAlimentar (banco da biblioteca), que é a rede de
  // segurança caso algum evento se perca.
  void _onUpdate(TaskUpdate update) async {
    if (update is! TaskStatusUpdate ||
        update.task.group != BackupService.grupo) {
      return;
    }
    final id = update.task.taskId;
    if (update.status == TaskStatus.complete) {
      await _store.marcarEnviado(id);
      if (mounted) setState(() => _enviadosIds.add(id));
      _sincronizarEAlimentar();
    } else if (update.status == TaskStatus.failed ||
        update.status == TaskStatus.notFound) {
      final t = (_tentativas[id] ?? 0) + 1;
      _tentativas[id] = t;
      if (!_pausado &&
          t <= 3 &&
          _emFila.contains(id) &&
          !_enviadosIds.contains(id)) {
        // Falhou mesmo depois das retentativas internas: tenta de novo com uma
        // sessão nova, no fim da fila.
        _pendentes.add(
            ItemBackup(id, update.task.filename, update.task.metaData));
      } else if (mounted) {
        setState(() {
          _falhasBg++;
          final desc = update.exception?.description;
          if (desc != null && desc.isNotEmpty) _erroBg = desc;
        });
      }
      _sincronizarEAlimentar();
    }
  }

  Future<void> _retomarJanela(List<Map<String, String>> job) async {
    if (job.isEmpty || _conta == null || _pausado) return;
    // Espera o motor restaurar a fila nativa antes de decidir o que falta.
    await Future.delayed(const Duration(seconds: 3));
    final enviados = await _store.enviados(); // leitura fresca
    final pendentes = job
        .where((m) {
          final id = m['id'] ?? '';
          return id.isNotEmpty && !enviados.contains(id);
        })
        .map(ItemBackup.fromMap)
        .toList();
    if (!mounted) return;
    final (ok, _) = await BackupService.prepararContexto(_gsi);
    if (!ok) return;
    if (!mounted) return;
    setState(() {
      _pendentes
        ..clear()
        ..addAll(pendentes);
    });
    // O sync pula sozinho os que já estão ativos no motor (não duplica).
    _sincronizarEAlimentar();
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
    // Aplica os tamanhos já em cache: o que a gente leu antes não é lido de novo.
    final cache = await _store.tamanhos();
    for (final it in items) {
      final c = cache[it.asset.id];
      if (c != null) it.bytes = c;
    }
    final Map<String, List<MediaItem>> grupos = {};
    for (final it in items) {
      grupos.putIfAbsent(it.pasta, () => []).add(it);
    }
    final pastas = grupos.entries.map((e) => Pasta(e.key, e.value)).toList()
      ..sort((a, b) => b.bytes.compareTo(a.bytes));
    final faltam = items.where((it) => !cache.containsKey(it.asset.id)).length;
    setState(() {
      _loading = false;
      _items = items;
      _pastas = pastas;
      _status = '${items.length} arquivos';
      _calculando = faltam > 0;
      _lidos = items.length - faltam;
    });
    if (faltam > 0) _calcularTamanhos();
  }

  Future<void> _calcularTamanhos() async {
    // Só lê o tamanho do que ainda não está no cache. Num celular com 19 mil
    // arquivos, as aberturas seguintes ficam quase instantâneas.
    final cache = await _store.tamanhos();
    final pendentes =
        _items.where((it) => !cache.containsKey(it.asset.id)).toList();
    final base = _items.length - pendentes.length;
    final novos = <String, int>{};
    for (var i = 0; i < pendentes.length; i++) {
      final it = pendentes[i];
      try {
        final f = await it.asset.file;
        it.bytes = f != null ? await f.length() : 0;
      } catch (_) {
        it.bytes = 0;
      }
      novos[it.asset.id] = it.bytes;
      if (i % 25 == 0) {
        if (mounted) setState(() => _lidos = base + i + 1);
        if (novos.length >= 200) {
          await _store.salvarTamanhos(novos);
          novos.clear();
        }
      }
    }
    if (novos.isNotEmpty) await _store.salvarTamanhos(novos);
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

  List<MediaItem> get _itensFiltrados {
    final base = _itensOrdenados;
    if (_filtro == 'drive') {
      return base.where((m) => _enviadosIds.contains(m.asset.id)).toList();
    }
    if (_filtro == 'foradrive') {
      return base.where((m) => !_enviadosIds.contains(m.asset.id)).toList();
    }
    return base;
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
              tooltip: 'Apagar do celular (só os que já subiram)',
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
    final faltam = total - feitos;
    return Container(
      width: double.infinity,
      color: _parchment,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                  pronto
                      ? Icons.cloud_done
                      : (_pausado ? Icons.pause_circle : Icons.cloud_upload),
                  size: 18,
                  color: _actionBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  pronto
                      ? 'Backup concluído: $feitos arquivos no Drive'
                      : (_pausado
                          ? 'Backup pausado: $feitos de $total'
                          : 'Subindo backup: $feitos de $total'),
                  style: const TextStyle(fontSize: 14, color: _ink),
                ),
              ),
              if (!pronto)
                _pausado
                    ? TextButton.icon(
                        onPressed: _conta == null ? null : _retomar,
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('Retomar'))
                    : TextButton.icon(
                        onPressed: _parar,
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text('Parar')),
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
                  _pausado
                      ? 'Pausado · faltam $faltam · toque em Retomar pra continuar'
                      : 'Subindo agora: ${_emAndamento.length} · na fila: ${_pendentes.length} · pode fechar o app',
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

  Widget _filtroDrive() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'todos', label: Text('Todos')),
            ButtonSegment(value: 'foradrive', label: Text('Fora')),
            ButtonSegment(value: 'drive', label: Text('No Drive')),
          ],
          selected: {_filtro},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _filtro = s.first),
        ),
      ),
    );
  }

  Widget _abaMidias() {
    final lista = _itensFiltrados;
    return Column(
      children: [
        _barraAcoes(),
        _filtroDrive(),
        Expanded(
          child: lista.isEmpty
              ? Center(
                  child: Text(
                      _filtro == 'drive'
                          ? 'Nada no Drive ainda.'
                          : 'Nada fora do Drive.',
                      style: const TextStyle(color: _inkMuted)))
              : ListView.builder(
                  itemCount: lista.length,
                  itemBuilder: (context, i) {
                    final item = lista[i];
                    final isVideo = item.asset.type == AssetType.video;
                    final jaSubiu = _enviadosIds.contains(item.asset.id);
                    return ListTile(
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => PreviewPage(item.asset))),
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
              final subiu =
                  p.itens.where((it) => _enviadosIds.contains(it.asset.id)).length;
              final todos = p.itens.length;
              final tudoNoDrive = todos > 0 && subiu == todos;
              return CheckboxListTile(
                value: _pastaToda(p),
                onChanged: (v) => _togglePasta(p, v),
                secondary: tudoNoDrive
                    ? const Icon(Icons.cloud_done, color: _actionBlue)
                    : (subiu > 0
                        ? Text('$subiu/$todos',
                            style: const TextStyle(
                                fontSize: 12, color: _inkMuted))
                        : null),
                title: Text(p.nome),
                subtitle: Text(
                    '${p.itens.length} arquivos • ${_fmt(p.bytes)}${tudoNoDrive ? ' • no Drive' : ''}'),
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
        if (mounted) {
          setState(() {
            _video = c;
            _carregando = false;
          });
        }
        return;
      }
    } else {
      final bytes = await widget.asset.originBytes;
      if (mounted) {
        setState(() {
          _imagem = bytes;
          _carregando = false;
        });
      }
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
