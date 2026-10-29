import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:background_downloader/background_downloader.dart';
import 'upload_store.dart';
import 'backup_service.dart';
import 'nativo.dart';

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
  String path; // caminho real no disco (MediaStore); vazio se não veio
  MediaItem(this.asset, this.bytes, this.pasta, {this.path = ''});

  String get id => asset.id;
  String get titulo => asset.title ?? 'sem nome';

  ItemBackup paraBackup() =>
      ItemBackup(id, titulo, pasta, path: path, bytes: bytes);
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
/// Rodada 10: pedidos em andamento são compartilhados (antes, cada rebuild da
/// tela disparava um pedido novo pra cada miniatura ainda não carregada).
class _ThumbCache {
  static final Map<String, Uint8List> _mapa = {};
  static final Map<String, Future<Uint8List?>> _emCurso = {};
  static const _max = 400;

  static Uint8List? pegar(String id) {
    final v = _mapa.remove(id);
    if (v != null) _mapa[id] = v; // reinsere no fim (mais recente)
    return v;
  }

  static void guardar(String id, Uint8List bytes) {
    if (_mapa.length >= _max) _mapa.remove(_mapa.keys.first);
    _mapa[id] = bytes;
  }

  static Future<Uint8List?> carregar(AssetEntity asset) {
    final id = asset.id;
    final pronto = pegar(id);
    if (pronto != null) return Future.value(pronto);
    return _emCurso[id] ??= asset
        .thumbnailDataWithSize(const ThumbnailSize(200, 200))
        .then((b) {
          if (b != null) guardar(id, b);
          return b;
        })
        .catchError((_) => null)
        .whenComplete(() => _emCurso.remove(id));
  }
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

  // Onboarding: null = ainda lendo a flag; false = mostrar; true = já viu.
  bool? _viuOnboarding;

  // Revisão dos dados: sobe a cada mudança em enviados/sessão/galeria. Tudo
  // que é caro de calcular (contagens, somas, filtros) fica cacheado por ela.
  int _rev = 0;

  // Ordenação e filtro cacheados.
  List<MediaItem>? _ordenadoCache;
  String _ordenadoChave = '';
  List<MediaItem>? _filtradoCache;
  String _filtradoChave = '';

  // Somas cacheadas pro card de missão e pras pastas.
  int _bytesNoCelular = 0;
  int _seguroCache = 0;
  int _seguroRev = -1;
  Map<String, int> _subiuPorPasta = {};
  int _subiuPorPastaRev = -1;

  // Estatísticas da sessão cacheadas (antes: 3 varreduras de 30 mil ids a
  // cada build, e havia build a cada arquivo concluído).
  int _statsRev = -1;
  int _cFeitos = 0;
  int _cBytesTotal = 0;
  int _cBytesFeitos = 0;

  final GoogleSignIn _gsi = GoogleSignIn(
    scopes: ['https://www.googleapis.com/auth/drive.file'],
  );
  GoogleSignInAccount? _conta;

  // Backup em segundo plano.
  final UploadStore _store = UploadStore();
  Set<String> _enviadosIds = {}; // ids já confirmados no Drive
  final Set<String> _emFila = {}; // total estável da sessão (denominador)
  final Map<String, ItemBackup> _itemDoJob = {}; // id -> item da sessão
  final Map<String, ItemBackup> _falhos = {}; // falha definitiva (botão retry)
  String? _erroBg; // último motivo de erro, pra mostrar na tela
  bool _pausado = false; // backup pausado (pelo usuário ou por Drive cheio)
  bool _driveCheio = false; // pausa automática por cota estourada
  bool _soWifi = false; // subir só no wifi (escolha do usuário)
  StreamSubscription<TaskUpdate>? _sub;

  // Janela deslizante guiada pelo banco da biblioteca (a fonte da verdade).
  static const int _janela = 40;
  static const int _concorrenciaPreparo = 6;
  final ListQueue<ItemBackup> _pendentes = ListQueue(); // não enfileirados
  final Set<String> _naFila = {}; // ids em _pendentes (sem repetição)
  final Set<String> _emAndamento = {}; // ativos no motor agora
  final Set<String> _preparando = {}; // saíram da fila, ainda abrindo sessão
  final Set<String> _processando = {}; // conclusão sendo conferida (MD5)
  final Map<String, int> _tentativas = {}; // re-tentativas por id
  final Map<String, int> _tentativasRede = {}; // quedas de rede por id
  final Map<String, DateTime> _ausentesDesde = {}; // candidatos a órfão
  DateTime _ultimaVarredura = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, DateTime> _paraLimpar = {}; // registros do banco a apagar
  final Set<String> _sumidos = {}; // saíram da galeria: tirar do job
  bool _reconciliando = false;
  bool _reconciliarDeNovo = false;
  bool _alimentando = false;
  bool _alimentarDeNovo = false;
  Timer? _poll; // sincroniza com o banco a cada 15s
  Timer? _refreshTimer; // setState agrupado (no máximo 2 por segundo)

  // Rede caiu: o motor espera (com espera crescente) sem gastar tentativa.
  DateTime? _esperarRedeAte;
  Duration _esperaRede = Duration.zero;
  bool _semRede = false;
  Timer? _timerRede;

  // Boot: o motor e a galeria carregam em paralelo; a retomada espera os dois.
  bool _motorPronto = false;
  bool _galeriaPronta = false;
  bool _acessoTotal = false; // permissão total à galeria (pra podar o job)
  bool _semeado = false; // fila da sessão montada nesta execução
  bool _retomando = false; // trava da retomada automática
  bool _subindoAgora = false; // trava contra toque duplo no Subir
  DateTime _ultimoLoginSilencioso = DateTime.fromMillisecondsSinceEpoch(0);

  // Duplicatas exatas: id do principal -> itens cobertos por ele.
  final Map<String, List<ItemBackup>> _dupsDe = {};

  // Velocidade e estimativa: bytes por id da sessão + amostras recentes.
  final Map<String, int> _bytesPorId = {};
  final List<(DateTime, int)> _amostras = []; // (quando, bytes concluídos)
  int _bytesSessao = 0; // concluídos nesta execução (média de fallback)

  // Sessão atual: pra telemetria e pro diálogo de vitória (1 vez só).
  DateTime? _inicioSessao;
  bool _celebrado = false;
  bool _fimRegistrado = false;
  DateTime _ultimaNotif = DateTime.fromMillisecondsSinceEpoch(0);

  // Integridade: MD5 conferido até este tamanho (acima disso, vale o tamanho).
  static const int _tetoMd5 = 256 * 1024 * 1024;

  // ---------------------------------------------------------------------------
  // Estatísticas cacheadas
  // ---------------------------------------------------------------------------

  void _mudou() => _rev++;

  void _calcStats() {
    if (_statsRev == _rev) return;
    var feitos = 0, bt = 0, bf = 0;
    for (final id in _emFila) {
      final b = _bytesPorId[id] ?? 0;
      bt += b;
      if (_enviadosIds.contains(id)) {
        feitos++;
        bf += b;
      }
    }
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

  /// setState agrupado: o motor pede refresh a cada evento, a tela redesenha
  /// no máximo a cada 500 ms. Em rajada de fotos pequenas eram dezenas de
  /// rebuilds por segundo da grade inteira.
  void _agendarRefresh() {
    if (_refreshTimer != null) return;
    _refreshTimer = Timer(const Duration(milliseconds: 500), () {
      _refreshTimer = null;
      if (mounted) setState(() {});
    });
  }

  // ---------------------------------------------------------------------------
  // Fila de pendentes (sem repetição)
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Motor: reconciliar (barato, roda sempre) + alimentar (lento, com trava)
  // ---------------------------------------------------------------------------

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
        if (item != null) _porNaFila(item);
      }
    }
  }

  /// Cobre duplicatas cujo principal já está no Drive (mesmo fileId).
  Future<void> _cobrirDuplicatas(Iterable<ItemBackup> dups) async {
    final lote = <NovoEnvio>[];
    for (final cob in dups) {
      if (_enviadosIds.contains(cob.id)) continue;
      if (!_enviadosIds.contains(cob.dup)) continue;
      lote.add((
        id: cob.id,
        fileId: _store.envioDe(cob.dup)?.fileId,
        bytes: cob.bytes > 0 ? cob.bytes : null,
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
      {bool contarVelocidade = true}) async {
    if (_enviadosIds.contains(id)) {
      // Já contado (ex.: a reconciliação viu antes do evento). Se agora veio
      // o fileId do Drive, guarda: é ele que libera o apagar com segurança.
      if (fileId != null) {
        await _store.marcarEnviado(id, fileId: fileId, bytes: bytes);
        final cobertos = _dupsDe[id];
        if (cobertos != null) {
          await _store.marcarEnviadosEmLote([
            for (final c in cobertos)
              if (_enviadosIds.contains(c.id) &&
                  _store.envioDe(c.id)?.fileId == null)
                (id: c.id, fileId: fileId, bytes: null)
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
    await _store.marcarEnviado(id, fileId: fileId, bytes: b > 0 ? b : null);
    if (contarVelocidade && _emFila.contains(id) && b > 0) {
      _amostras.add((DateTime.now(), b));
      _bytesSessao += b;
    }
    _paraLimpar[id] = DateTime.now();
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
    });
    _store.limparJob();
    _erroBg = null;
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
    });
  }

  void _mostrarVitoria(int arquivos, int bytes) {
    final liberaveis = _bytesSeguros;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup concluído!'),
        content: Text(
            '$arquivos arquivos (${_fmt(bytes)}) estão seguros no Drive.\n\n'
            '${liberaveis > 0 ? 'Agora dá pra liberar ${_fmt(liberaveis)} do celular.' : ''}'),
        actions: [
          TextButton(
            onPressed: () => Nativo.compartilhar(
                'Acabei de guardar $arquivos fotos e vídeos (${_fmt(bytes)}) na nuvem e liberar espaço no celular com o Limpa Memória.'),
            child: const Text('Compartilhar'),
          ),
          if (liberaveis > 0)
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _apagarEnviados();
              },
              child: Text('Liberar ${_fmt(liberaveis)}'),
            )
          else
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Fechar')),
        ],
      ),
    );
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
        : (eta.isNotEmpty ? '$eta · deixe o app aberto na tomada' : 'Subindo…');
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
      } catch (_) {}

      final vagas = _janela - _emAndamento.length - _preparando.length;
      while (lote.length < vagas && _pendentes.isNotEmpty) {
        final item = _tirarDaFila()!;
        if (item.dup.isNotEmpty ||
            _enviadosIds.contains(item.id) ||
            _emAndamento.contains(item.id) ||
            _preparando.contains(item.id) ||
            _processando.contains(item.id) ||
            !_emFila.contains(item.id)) {
          continue;
        }
        lote.add(item);
        _preparando.add(item.id);
      }
      if (lote.isEmpty) return;

      await BackupService.garantirSubpastas(_gsi, lote.map((e) => e.pasta));

      var i = 0;
      while (i < lote.length) {
        if (_pausado) break;
        final leva = lote.sublist(i, min(i + _concorrenciaPreparo, lote.length));
        i += leva.length;
        final res = await Future.wait(leva.map((item) async {
          final (ok, erro) =
              await BackupService.enfileirarUm(_gsi, item, soWifi: _soWifi);
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
          if (erro == BackupService.erroDriveCheio) {
            devolver.add(r.item);
            driveCheio = true;
          } else if (erro == BackupService.erroSumiu) {
            _tirarDaSessao(id);
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
              if (erro != null && erro.isNotEmpty) _erroBg = erro;
            }
          }
        }
        _devolverNaFrente(devolver);
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

  /// Sem rede: espera crescente (15s, 30s, 1 min… até 5 min) antes de tentar
  /// preparar de novo. Antes, cada queda de rede queimava as 3 tentativas
  /// dos últimos arquivos em poucos minutos e eles viravam "falhou".
  void _esperarRede() {
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
    await _store.setPausado(true);
    Nativo.limparNotificacao();
    if (mounted) {
      setState(() {
        _pausado = true;
        _driveCheio = true;
        _erroBg =
            'O Drive encheu. Libere espaço na conta (ou assine mais) e toque em Retomar.';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Caminho feliz: missão, sugestões e fechamento do ciclo
  // ---------------------------------------------------------------------------

  /// Card no topo: o resumo da missão e os 2 botões que resolvem a jornada.
  Widget _cardMissao() {
    if (_items.isEmpty) return const SizedBox.shrink();
    final subindo =
        _emFila.isNotEmpty && _bgFeitos < _bgTotal && !_fimComFalhas;
    if (subindo) return const SizedBox.shrink(); // durante o backup, o banner manda
    final liberaveis = _bytesSeguros;
    final foraDrive = max(0, _bytesNoCelular - liberaveis);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _parchment,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Seu celular tem ${_fmt(_bytesNoCelular)} em fotos e vídeos',
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600, color: _ink),
          ),
          const SizedBox(height: 4),
          Text(
            liberaveis > 0
                ? '${_fmt(liberaveis)} já estão seguros no Drive e podem sair do celular. ${foraDrive > 0 ? '${_fmt(foraDrive)} ainda estão só aqui.' : ''}'
                : '${_fmt(foraDrive)} ainda estão só no celular.',
            style: const TextStyle(fontSize: 13, color: _inkMuted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton(
                onPressed: _abrirSugestoes,
                child: const Text('Liberar espaço'),
              ),
              if (liberaveis > 0)
                TextButton(
                  onPressed: _apagarEnviados,
                  child: Text('Apagar ${_fmt(liberaveis)} seguros'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Sugestões de seleção (estilo Files by Google): grupos prontos com o
  /// quanto cada um libera. Heurísticas baratas de pasta, tamanho e data.
  Future<void> _abrirSugestoes() async {
    final agora = DateTime.now();
    final umAno = agora.subtract(const Duration(days: 365));
    final fora = _items.where((m) => !_enviadosIds.contains(m.id)).toList();

    List<MediaItem> grupo(bool Function(MediaItem) f) => fora.where(f).toList();
    final grupos = <(String, String, List<MediaItem>, int)>[];
    void add(String titulo, String desc, List<MediaItem> itens) {
      if (itens.isNotEmpty) {
        grupos.add(
            (titulo, desc, itens, itens.fold<int>(0, (s, m) => s + m.bytes)));
      }
    }

    add(
        'Vídeos grandes',
        'Acima de 100 MB',
        grupo((m) =>
            m.asset.type == AssetType.video && m.bytes > 100 * 1024 * 1024));
    add('WhatsApp', 'Fotos e vídeos recebidos',
        grupo((m) => m.pasta.toLowerCase().contains('whatsapp')));
    add('Mais antigos que 1 ano', 'Você quase não abre',
        grupo((m) => m.asset.createDateTime.isBefore(umAno)));
    add('Screenshots', 'Capturas de tela',
        grupo((m) => m.pasta.toLowerCase().contains('screenshot')));

    if (grupos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Nada óbvio pra sugerir: tudo que sobrou é recente e pequeno. Use a lista pra escolher.')));
      return;
    }
    if (_conta == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Entre com o Google primeiro (ícone lá em cima).')));
      return;
    }

    final marcados = <int>{for (var i = 0; i < grupos.length; i++) i};
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final selecionados = <MediaItem>{};
          for (final i in marcados) {
            selecionados.addAll(grupos[i].$3);
          }
          final bytes = selecionados.fold<int>(0, (s, m) => s + m.bytes);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('O que guardar no Drive?',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  const Text(
                      'Sugestões prontas. Desmarque o que quiser manter só no celular.',
                      style: TextStyle(fontSize: 13, color: _inkMuted)),
                  const SizedBox(height: 8),
                  ...List.generate(grupos.length, (i) {
                    final (titulo, desc, itens, gb) = grupos[i];
                    return CheckboxListTile(
                      value: marcados.contains(i),
                      onChanged: (v) => setSheet(() {
                        if (v == true) {
                          marcados.add(i);
                        } else {
                          marcados.remove(i);
                        }
                      }),
                      title: Text(titulo),
                      subtitle: Text(
                          '$desc · ${_milhar(itens.length)} arquivos · ${_fmt(gb)}'),
                      contentPadding: EdgeInsets.zero,
                    );
                  }),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: selecionados.isEmpty
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              setState(() {
                                _selected
                                  ..clear()
                                  ..addAll(selecionados);
                              });
                              _subir();
                            },
                      child: Text(selecionados.isEmpty
                          ? 'Nada marcado'
                          : 'Subir ${_milhar(selecionados.length)} arquivos (${_fmt(bytes)})'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Ações do usuário
  // ---------------------------------------------------------------------------

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
            onSelected: (v) => setState(() {
              _ordem = v;
              _ordenadoCache = null;
            }),
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
      if (!mounted) return;
      setState(() => _conta = conta);
      if (conta != null) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Conectado como ${conta.email}')));
        _tick(); // retoma backup pendente, se houver
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
    if (!mounted) return;
    setState(() => _conta = null);
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
      if (conta != null && mounted) setState(() => _conta = conta);
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

  Future<void> _alternarWifi() async {
    final novo = !_soWifi;
    await _store.setSoWifi(novo);
    if (!mounted) return;
    setState(() => _soWifi = novo);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(novo
            ? 'Só no wifi: os próximos arquivos esperam uma rede wifi.'
            : 'Qualquer rede: sobe no wifi e em dados móveis.')));
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
    const margem = 200 * 1024 * 1024; // 200 MB de folga
    final orcamento = livre - margem;
    final ordenados = List<ItemBackup>.from(pendentes)
      ..sort((a, b) => b.bytes.compareTo(a.bytes));
    final cabem = <ItemBackup>[];
    var soma = 0;
    for (final it in ordenados) {
      if (it.bytes <= 0) continue;
      if (soma + it.bytes > orcamento) continue;
      soma += it.bytes;
      cabem.add(it);
    }
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
    final noDrive = await BackupService.listarNoDrive(_gsi);
    if (noDrive == null || noDrive.isEmpty) return 0;
    final porChave = <String, ArquivoDrive>{};
    for (final a in noDrive) {
      porChave['${a.nome}|${a.pasta}|${a.bytes}'] = a;
    }
    final novos = <NovoEnvio>[];
    for (final it in lista) {
      final a = porChave['${it.titulo}|${it.pasta}|${it.bytes}'];
      if (a == null) continue;
      novos.add((id: it.id, fileId: a.fileId, bytes: it.bytes));
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
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Entre com o Google primeiro.')));
      return;
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
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Não consegui começar o backup'),
          content: Text(BackupService.ehRede(erroCtx)
              ? 'Sem conexão com o Google agora. Confira a internet e tente de novo.'
              : (erroCtx ?? 'Falha ao preparar o Drive.')),
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
      setState(() => _mudou());
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Tudo que você marcou já está no Drive.')));
      return;
    }

    // Duplicatas exatas (mesmo nome + mesmo tamanho, clássico do WhatsApp):
    // sobe 1, as outras são cobertas pelo mesmo arquivo do Drive. Arquivo
    // igual que JÁ subiu antes também serve de principal.
    final porChaveDup = <String, String>{}; // titulo|bytes -> id do principal
    for (final m in _items) {
      if (m.bytes > 0 && _enviadosIds.contains(m.id)) {
        porChaveDup.putIfAbsent('${m.titulo}|${m.bytes}', () => m.id);
      }
    }
    var duplicatas = 0;
    pendentesItens = pendentesItens.map((it) {
      if (it.bytes <= 0) return it;
      final chave = '${it.titulo}|${it.bytes}';
      final principal = porChaveDup[chave];
      if (principal == null) {
        porChaveDup[chave] = it.id;
        return it;
      }
      duplicatas++;
      return it.comDup(principal);
    }).toList();

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
      pendentesItens = pendentesItens
          .where((it) => it.dup.isEmpty
              ? idsAparados.contains(it.id)
              : (idsAparados.contains(it.dup) ||
                  _enviadosIds.contains(it.dup)))
          .toList();
    }
    mergedItens = [
      ...mergedItens.where((it) => _enviadosIds.contains(it.id)),
      ...pendentesItens,
    ];

    await _prepararJobGrande(pendentesItens
        .where((it) => it.dup.isEmpty)
        .fold<int>(0, (s, it) => s + it.bytes));

    // Maiores primeiro: libera mais espaço mais cedo.
    final fila = pendentesItens.where((it) => it.dup.isEmpty).toList()
      ..sort((a, b) => b.bytes.compareTo(a.bytes));

    await _store.salvarJob(mergedItens.map((e) => e.toMap()).toList());
    await _store.setPausado(false);
    BackupService.invalidarListagem();

    if (!mounted) return;
    setState(() {
      _pausado = false;
      _driveCheio = false;
      _falhos.clear();
      _erroBg = null;
      _tentativas.clear();
      _tentativasRede.clear();
      _ausentesDesde.clear();
      _amostras.clear();
      _bytesSessao = 0;
      _inicioSessao = DateTime.now();
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Backup começou. Deixe o app aberto na tomada pra ir até o fim.$msgDup')));
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
    setState(() {
      _pausado = true;
      _limparFila();
      _mudou();
    });
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
    setState(() {
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
    setState(() {
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

  // ---------------------------------------------------------------------------
  // Apagar do celular (com conferência real no Drive)
  // ---------------------------------------------------------------------------

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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Entre com o Google: sem conferir no Drive, nada é apagado.')));
      return;
    }

    final bytes = candidatos.fold<int>(0, (s, id) => s + itemPorId[id]!.bytes);
    final confirma = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apagar do celular'),
        content: Text(
            'Apagar ${_milhar(candidatos.length)} arquivos (${_fmt(bytes)})?\n\nAntes de apagar, o app confere um a um no Drive. O que não estiver conferido fica no celular.\n\nO Android vai pedir confirmação em algumas levas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Conferir e apagar')),
        ],
      ),
    );
    if (confirma != true || !mounted) return;

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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Não consegui conferir no Drive (internet?). Sem conferência, nada é apagado.')));
      return;
    }
    final tamPorFileId = <String, int>{};
    final porChave = <String, int>{}; // nome|pasta|bytes -> quantos existem
    for (final a in noDrive) {
      tamPorFileId[a.fileId] = a.bytes;
      final chave = '${a.nome}|${a.pasta}|${a.bytes}';
      porChave[chave] = (porChave[chave] ?? 0) + 1;
    }
    final verificados = <String>[];
    var naoConferidos = 0;
    for (final id in candidatos) {
      final info = _store.envioDe(id);
      final item = itemPorId[id]!;
      final fid = info?.fileId;
      var ok = false;
      if (fid != null) {
        final tam = tamPorFileId[fid];
        // Confere o tamanho do Drive contra o enviado E contra o arquivo
        // que está no celular agora (se mudou depois do backup, fica).
        final esperado = item.bytes > 0 ? item.bytes : info?.bytes;
        ok = tam != null &&
            (esperado == null || tam == esperado) &&
            (info?.bytes == null || tam == info!.bytes);
      } else {
        final chave = '${item.titulo}|${item.pasta}|${item.bytes}';
        final quantos = porChave[chave] ?? 0;
        if (quantos > 0 && item.bytes > 0) {
          porChave[chave] = quantos - 1;
          ok = true;
        }
      }
      if (ok) {
        verificados.add(id);
      } else {
        naoConferidos++;
      }
    }
    if (verificados.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Não consegui conferir nenhum arquivo no Drive. Nada foi apagado.')));
      return;
    }

    // Lotes que cabem no limite do Android. Usuário recusou um lote = para.
    // Erro num lote (ex.: um arquivo sumiu no meio) = tenta em lotes menores.
    final apagadosAll = <String>[];
    var recusou = false;
    Future<bool> apagarLote(List<String> ids) async {
      try {
        final apag = await PhotoManager.editor.deleteWithIds(ids);
        apagadosAll.addAll(apag);
        if (apag.isEmpty) recusou = true;
        return true;
      } catch (_) {
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
    setState(() {
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text([
      'Apagados ${_milhar(setApagados.length)} do celular.',
      if (recusou && restam > 0)
        '${_milhar(restam)} ficaram (confirmação recusada).',
      if (naoConferidos > 0)
        '${_milhar(naoConferidos)} não conferiram no Drive e ficaram no celular.',
    ].join(' '))));
  }

  // ---------------------------------------------------------------------------
  // Boot
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _tick());
  }

  /// Decide entre onboarding e o app. O motor e a galeria só sobem depois que
  /// o onboarding foi visto (é ele que explica as permissões que vêm a seguir).
  Future<void> _boot() async {
    await _store.init(await Nativo.dirDados());
    _enviadosIds = await _store.enviados();
    _mudou();
    final viu = await _store.viuOnboarding();
    if (!mounted) return;
    if (!viu) {
      setState(() => _viuOnboarding = false);
      return;
    }
    setState(() => _viuOnboarding = true);
    _iniciarBackupEngine();
    _load();
  }

  Future<void> _concluirOnboarding() async {
    await _store.marcarOnboardingVisto();
    if (!mounted) return;
    setState(() => _viuOnboarding = true);
    _iniciarBackupEngine();
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _refreshTimer?.cancel();
    _timerRede?.cancel();
    _sub?.cancel();
    _store.gravarAgora();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _store.gravarAgora();
    } else if (state == AppLifecycleState.resumed) {
      _tick(); // voltou pro app: sincroniza na hora
    }
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
            [for (final id in concluidos) (id: id, fileId: null, bytes: null)]);
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
    } catch (_) {}

    try {
      final conta = await _gsi
          .signInSilently()
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
      _ultimoLoginSilencioso = DateTime.now();
      if (conta != null && mounted) setState(() => _conta = conta);
    } catch (_) {}

    final job = await _store.job();
    final pausado = await _store.pausado();
    final soWifi = await _store.soWifi();
    if (!mounted) return;
    setState(() {
      _pausado = pausado;
      _soWifi = soWifi;
      if (job.isNotEmpty) {
        _carregarSessao(job.map(ItemBackup.fromMap).toList());
        _inicioSessao ??= DateTime.now();
      }
      _mudou();
    });
    _motorPronto = true;
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
    } catch (_) {}

    final pendentes = [
      for (final id in _emFila)
        if (!_enviadosIds.contains(id) &&
            !_emAndamento.contains(id) &&
            (_itemDoJob[id]?.dup.isEmpty ?? false))
          _itemDoJob[id]!
    ]..sort((a, b) => b.bytes.compareTo(a.bytes)); // maiores primeiro
    if (!mounted) return;
    setState(() {
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
          if (t <= 3) {
            _porNaFila(item, frente: true);
            _erroBg = 'Um arquivo chegou diferente no Drive; refazendo.';
          } else {
            _falhos[id] = item;
            _erroBg =
                '"${item.titulo}" chegou diferente no Drive 3 vezes (${meta.pasta}).';
          }
          _mudou();
          _agendarRefresh();
          return;
        }
      }

      await _confirmarEnvio(id, fileId, bytes);
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
    if (exc is TaskConnectionException) {
      // Rede caiu de vez durante o upload (a biblioteca já tinha tentado 10x).
      // Não gasta tentativa normal: espera a rede e tenta de novo, até 20x.
      final tr = (_tentativasRede[id] ?? 0) + 1;
      _tentativasRede[id] = tr;
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
      final desc = exc?.description;
      if (desc != null && desc.isNotEmpty) _erroBg = desc;
    }
    _mudou();
    _agendarRefresh();
    _tick();
  }

  // ---------------------------------------------------------------------------
  // Galeria
  // ---------------------------------------------------------------------------

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
      setState(() {
        _loading = false;
        _status = 'Permissão negada. Libere o acesso a fotos e tente de novo.';
      });
      return;
    }
    _acessoTotal = ps.isAuth;
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
    );
    if (paths.isEmpty) {
      setState(() {
        _loading = false;
        _status = 'Nenhuma mídia encontrada.';
      });
      _galeriaPronta = true;
      _tentarRetomar();
      return;
    }
    final all = paths.first;
    final count = await all.assetCountAsync;

    // Consulta nativa em paralelo com a paginação (roda em thread própria).
    final infoFut = Nativo.midias();

    const pagina = 1000;
    final List<MediaItem> items = [];
    for (var inicio = 0; inicio < count; inicio += pagina) {
      final assets = await all.getAssetListRange(
          start: inicio, end: min(inicio + pagina, count));
      items.addAll([for (final a in assets) MediaItem(a, 0, _nomePasta(a))]);
      if (inicio == 0 && mounted) {
        setState(() {
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
    final cacheFallback = await _store.tamanhos();
    for (final it in items) {
      final info = midiaInfo[it.id];
      if (info != null) {
        if (info.bytes > 0) it.bytes = info.bytes;
        it.path = info.caminho;
      }
      if (it.bytes == 0) {
        final c = cacheFallback[it.id];
        if (c != null) it.bytes = c;
      }
    }
    final pastas = _agruparPastas(items);
    final faltam = items.where((it) => it.bytes == 0).length;
    if (!mounted) return;
    setState(() {
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
        if (mounted) setState(() => _lidos = base + i + 1);
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
    setState(() {
      _lidos = _items.length;
      _calculando = false;
      _ordenadoCache = null;
      _filtradoCache = null;
      _bytesNoCelular = _items.fold(0, (s, m) => s + m.bytes);
      for (final p in _pastas) {
        p.recalcular();
      }
      _pastas.sort((a, b) => b.bytes.compareTo(a.bytes));
      _mudou();
    });
  }

  String _nomePasta(AssetEntity a) {
    final rp = a.relativePath ?? '';
    final partes = rp.split('/').where((p) => p.isNotEmpty).toList();
    return partes.isEmpty ? 'Outros' : partes.last;
  }

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
    if (_filtro == 'todos') return base;
    final chave = '$_filtro|$_rev|$_ordenadoChave';
    if (_filtradoCache != null && _filtradoChave == chave) {
      return _filtradoCache!;
    }
    final noDrive = _filtro == 'drive';
    final lista = base
        .where((m) => _enviadosIds.contains(m.id) == noDrive)
        .toList(growable: false);
    _filtradoCache = lista;
    _filtradoChave = chave;
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

  /// 19000 -> "19.000"
  String _milhar(int n) {
    final s = n.abs().toString();
    final buf = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  int get _totalSelecionado => _selected.fold(0, (s, i) => s + i.bytes);

  void _toggle(MediaItem item) => setState(() {
        if (_selected.contains(item)) {
          _selected.remove(item);
        } else {
          _selected.add(item);
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

  // ---------------------------------------------------------------------------
  // Velocidade e estimativa
  // ---------------------------------------------------------------------------

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

  String _eta(int bytesRestantes) {
    final v = _velocidade;
    if (v <= 0 || bytesRestantes <= 0) return '';
    final s = (bytesRestantes / v).round();
    if (s < 90) return '~1 min restante';
    if (s < 3600) return '~${(s / 60).round()} min restantes';
    final h = s ~/ 3600;
    final m = ((s % 3600) / 60).round();
    if (h >= 48) return '~${(h / 24).round()} dias restantes';
    return '~${h}h${m.toString().padLeft(2, '0')} restantes';
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_viuOnboarding == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_viuOnboarding == false) {
      return OnboardingPage(
        conta: _conta,
        onLogin: _login,
        onConcluir: _concluirOnboarding,
      );
    }
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
              icon: Icon(_soWifi ? Icons.wifi : Icons.wifi_tethering),
              tooltip: _soWifi
                  ? 'Subindo só no wifi (toque pra liberar dados móveis)'
                  : 'Subindo em qualquer rede (toque pra exigir wifi)',
              onPressed: _alternarWifi,
            ),
            IconButton(
              icon: const Icon(Icons.cloud_queue),
              tooltip: 'Espaço no Drive',
              onPressed: _conta == null ? null : _checarEspaco,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Apagar do celular (confere no Drive antes)',
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
                  ],
                  _cardMissao(),
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
                                '${_milhar(_selected.length)} selecionados • ${_fmt(_totalSelecionado)}')),
                        FilledButton(
                            onPressed: _selected.isEmpty || _subindoAgora
                                ? null
                                : _subir,
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
    _calcStats();
    final total = _bgTotal;
    final feitos = _cFeitos;
    final pronto = feitos >= total;
    final fimFalhas = !pronto && _fimComFalhas;
    final bytesTotal = _cBytesTotal;
    final bytesFeitos = _cBytesFeitos;
    final pct = bytesTotal > 0
        ? bytesFeitos / bytesTotal
        : (total == 0 ? 0.0 : feitos / total);
    final faltam = total - feitos;
    final eta = (!pronto && !_pausado && !fimFalhas)
        ? _eta(bytesTotal - bytesFeitos)
        : '';
    final vel = _velocidade;
    final liberaveis = _bytesSeguros;

    final String titulo;
    if (pronto) {
      titulo = 'Backup concluído: ${_milhar(feitos)} arquivos no Drive';
    } else if (fimFalhas) {
      titulo =
          'Backup parou: ${_milhar(feitos)} de ${_milhar(total)} · ${_milhar(faltam)} não subiram';
    } else if (_pausado) {
      titulo = 'Backup pausado: ${_milhar(feitos)} de ${_milhar(total)}';
    } else {
      titulo = 'Subindo backup: ${_milhar(feitos)} de ${_milhar(total)}';
    }

    final String? detalhe;
    if (pronto || fimFalhas) {
      detalhe = null;
    } else if (_pausado) {
      detalhe =
          'Pausado · faltam ${_milhar(faltam)} · toque em Retomar pra continuar';
    } else if (_conta == null) {
      detalhe = 'Entre com o Google (ícone lá em cima) pra continuar.';
    } else if (_semRede) {
      detalhe =
          'Sem internet ou o Drive pediu pausa. Continua sozinho quando voltar · na fila: ${_milhar(_pendentes.length)}';
    } else {
      detalhe =
          'Subindo agora: ${_emAndamento.length + _preparando.length} · na fila: ${_milhar(_pendentes.length)}'
          '${eta.isNotEmpty ? ' · $eta' : ''}'
          '${vel > 0 ? ' · ${_fmt(vel.round())}/s' : ''}';
    }

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
                      : (fimFalhas
                          ? Icons.error_outline
                          : (_pausado
                              ? Icons.pause_circle
                              : (_semRede
                                  ? Icons.cloud_off
                                  : Icons.cloud_upload))),
                  size: 18,
                  color: _actionBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(titulo,
                    style: const TextStyle(fontSize: 14, color: _ink)),
              ),
              if (!pronto && !fimFalhas)
                _pausado
                    ? TextButton.icon(
                        onPressed: _conta == null ? null : _retomar,
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('Retomar'))
                    : TextButton.icon(
                        onPressed: _parar,
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text('Parar')),
              if ((pronto || fimFalhas) && liberaveis > 0)
                TextButton.icon(
                    onPressed: _apagarEnviados,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text('Liberar ${_fmt(liberaveis)}')),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 6,
              backgroundColor: _hairline,
              value: pct.clamp(0.0, 1.0),
            ),
          ),
          if (detalhe != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(detalhe,
                  style: const TextStyle(fontSize: 12, color: _inkMuted)),
            ),
          if (!pronto && !_pausado && !fimFalhas && _conta != null)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                  'Com o app fechado sobem só os que já estão na fila do Android. Pra ir até o fim, deixe aberto na tomada.',
                  style: TextStyle(fontSize: 12, color: _inkMuted)),
            ),
          if (_falhos.isNotEmpty || _erroBg != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _erroBg != null
                          ? 'Problema: $_erroBg'
                          : '${_milhar(_falhos.length)} arquivo(s) falharam.',
                      style:
                          const TextStyle(fontSize: 12, color: Color(0xFFB00020)),
                    ),
                  ),
                  if (_falhos.isNotEmpty && !_driveCheio)
                    TextButton(
                        onPressed: _tentarFalhosDeNovo,
                        child:
                            Text('Tentar de novo (${_milhar(_falhos.length)})')),
                ],
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
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                  ),
                  itemCount: lista.length,
                  itemBuilder: (context, i) {
                    final item = lista[i];
                    return _CelulaMidia(
                      key: ValueKey(item.id),
                      item: item,
                      selecionado: _selected.contains(item),
                      noDrive: _enviadosIds.contains(item.id),
                      tamanho: _fmt(item.bytes),
                      onTap: () => _toggle(item),
                      onLongPress: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  PreviewPage(item.asset, caminho: item.path))),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _abaPastas() {
    final subiuMapa = _subiuPorPastaMapa;
    return Column(
      children: [
        _barraAcoes(),
        Expanded(
          child: ListView.builder(
            itemCount: _pastas.length,
            itemBuilder: (context, i) {
              final p = _pastas[i];
              final subiu = subiuMapa[p.nome] ?? 0;
              final todos = p.itens.length;
              final tudoNoDrive = todos > 0 && subiu >= todos;
              return CheckboxListTile(
                value: _pastaToda(p),
                onChanged: (v) => _togglePasta(p, v),
                secondary: tudoNoDrive
                    ? const Icon(Icons.cloud_done, color: _actionBlue)
                    : (subiu > 0
                        ? Text('${_milhar(subiu)}/${_milhar(todos)}',
                            style: const TextStyle(
                                fontSize: 12, color: _inkMuted))
                        : null),
                title: Text(p.nome),
                subtitle: Text(
                    '${_milhar(p.itens.length)} arquivos • ${_fmt(p.bytes)}${tudoNoDrive ? ' • no Drive' : ''}'),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Célula da grade: miniatura cacheada, badge de tamanho, nuvem quando já
/// subiu, círculo de seleção. Toque seleciona; segurar abre a prévia.
class _CelulaMidia extends StatelessWidget {
  final MediaItem item;
  final bool selecionado;
  final bool noDrive;
  final String tamanho;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _CelulaMidia({
    super.key,
    required this.item,
    required this.selecionado,
    required this.noDrive,
    required this.tamanho,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isVideo = item.asset.type == AssetType.video;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Thumb(id: item.asset.id, asset: item.asset, isVideo: isVideo),
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
                  style: const TextStyle(color: Colors.white, fontSize: 10)),
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
    );
  }
}

/// Miniatura com cache LRU. Stateful: o pedido da miniatura nasce UMA vez
/// por célula (antes, cada rebuild da tela criava um pedido novo).
class _Thumb extends StatefulWidget {
  final String id;
  final AssetEntity asset;
  final bool isVideo;
  const _Thumb({required this.id, required this.asset, required this.isVideo});

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  Uint8List? _bytes;
  Future<Uint8List?>? _fut;

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
    _bytes = _ThumbCache.pegar(widget.id);
    _fut = _bytes == null ? _ThumbCache.carregar(widget.asset) : null;
  }

  @override
  Widget build(BuildContext context) {
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

/// Onboarding de 3 telas, mostrado uma vez. Explica o app, avisa das
/// permissões que vêm a seguir e conecta o Google.
class OnboardingPage extends StatefulWidget {
  final GoogleSignInAccount? conta;
  final Future<void> Function() onLogin;
  final Future<void> Function() onConcluir;
  const OnboardingPage({
    super.key,
    required this.conta,
    required this.onLogin,
    required this.onConcluir,
  });

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _pc = PageController();
  int _pagina = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Widget _tela(IconData icone, String titulo, String texto, {Widget? extra}) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icone, size: 56, color: _actionBlue),
          const SizedBox(height: 24),
          Text(titulo,
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Text(texto,
              style: const TextStyle(
                  fontSize: 16, color: _inkMuted, height: 1.4)),
          if (extra != null) ...[const SizedBox(height: 24), extra],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ultima = _pagina == 2;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pc,
                onPageChanged: (p) => setState(() => _pagina = p),
                children: [
                  _tela(
                    Icons.photo_library_outlined,
                    'Celular cheio, memórias salvas',
                    'O Limpa Memória guarda suas fotos e vídeos no seu Google Drive, na qualidade original, e só depois apaga do celular o que conferiu que está seguro na nuvem.',
                  ),
                  _tela(
                    Icons.lock_open_outlined,
                    'Ele vai pedir 2 permissões',
                    'Acesso às fotos: pra listar e subir suas mídias.\n\nNotificações: pra você acompanhar o backup com a tela apagada.\n\nSó isso. Nada sai do celular além dos arquivos que VOCÊ mandar pro seu Drive.',
                  ),
                  _tela(
                    Icons.cloud_outlined,
                    'Conecte seu Google',
                    widget.conta == null
                        ? 'O backup vai pro Drive da sua conta Google. O app só enxerga a pasta que ele mesmo cria; o resto do seu Drive fica invisível pra ele.'
                        : 'Conectado como ${widget.conta!.email}. Tudo pronto.',
                    extra: widget.conta == null
                        ? FilledButton.icon(
                            onPressed: () async {
                              await widget.onLogin();
                              if (mounted) setState(() {});
                            },
                            icon: const Icon(Icons.login),
                            label: const Text('Entrar com Google'),
                          )
                        : null,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
              child: Row(
                children: [
                  ...List.generate(
                    3,
                    (i) => Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _pagina ? _actionBlue : _hairline,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (!ultima)
                    TextButton(
                        onPressed: widget.onConcluir,
                        child: const Text('Pular')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: ultima
                        ? widget.onConcluir
                        : () => _pc.nextPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut),
                    child: Text(ultima ? 'Começar' : 'Avançar'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PreviewPage extends StatefulWidget {
  final AssetEntity asset;
  final String caminho; // caminho real (MediaStore): abre sem copiar
  const PreviewPage(this.asset, {super.key, this.caminho = ''});
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
    try {
      if (_isVideo) {
        File? f;
        if (widget.caminho.isNotEmpty) {
          final direto = File(widget.caminho);
          if (await direto.exists()) f = direto;
        }
        f ??= await widget.asset.file;
        if (f != null) {
          final c = VideoPlayerController.file(f);
          await c.initialize();
          await c.setLooping(true);
          await c.play();
          if (!mounted) {
            await c.dispose();
            return;
          }
          setState(() {
            _video = c;
            _carregando = false;
          });
          return;
        }
      } else {
        // Imagem: versão reduzida (1600 px) em vez dos bytes originais.
        // Foto de 50 MP decodificada inteira estourava memória.
        final bytes = await widget.asset
            .thumbnailDataWithSize(const ThumbnailSize(1600, 1600),
                quality: 90);
        if (mounted) {
          setState(() {
            _imagem = bytes;
            _carregando = false;
          });
        }
        return;
      }
    } catch (_) {}
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
