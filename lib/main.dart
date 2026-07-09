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
}

class Pasta {
  final String nome;
  final List<MediaItem> itens;
  Pasta(this.nome, this.itens);
  int get bytes => itens.fold(0, (s, i) => s + i.bytes);
}

/// Cache LRU de miniaturas em memória. O mesmo Uint8List reaproveitado faz o
/// Flutter reaproveitar também a imagem decodificada, então o scroll na grade
/// de milhares de itens deixa de re-decodificar a cada rebuild.
class _ThumbCache {
  static final Map<String, Uint8List> _mapa = {};
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

  // Ordenação cacheada: ordenar 19 mil itens a cada build era jank de horas.
  List<MediaItem>? _ordenadoCache;
  String _ordenadoChave = '';

  // Soma de bytes cacheada pro card de missão.
  int _bytesNoCelular = 0;
  int _seguroCache = 0;
  String _seguroChave = '';

  final GoogleSignIn _gsi = GoogleSignIn(
    scopes: ['https://www.googleapis.com/auth/drive.file'],
  );
  GoogleSignInAccount? _conta;

  // Backup em segundo plano.
  final UploadStore _store = UploadStore();
  Set<String> _enviadosIds = {}; // ids já confirmados no Drive
  final Set<String> _emFila = {}; // total estável da sessão (denominador)
  int _falhasBg = 0; // uploads que falharam de vez
  final List<ItemBackup> _falhos = []; // os itens falhos, pro botão de retry
  String? _erroBg; // último motivo de erro, pra mostrar na tela
  bool _pausado = false; // backup pausado (pelo usuário ou por Drive cheio)
  bool _driveCheio = false; // pausa automática por cota estourada
  bool _soWifi = false; // subir só no wifi (escolha do usuário)
  StreamSubscription<TaskUpdate>? _sub;

  // Janela deslizante guiada pelo banco da biblioteca (a fonte da verdade).
  static const int _janela = 40;
  static const int _concorrenciaPreparo = 6;
  final List<ItemBackup> _pendentes = []; // ainda não enfileirados
  final Set<String> _emAndamento = {}; // ativos no motor agora (só pra exibir)
  final Map<String, int> _tentativas = {}; // re-tentativas por id
  bool _reconciliando = false; // trava de reentrância (parte barata)
  bool _alimentando = false; // trava de reentrância (parte lenta)
  Timer? _poll; // sincroniza com o banco a cada 15s

  // Duplicatas exatas: id do principal -> itens cobertos por ele.
  final Map<String, List<ItemBackup>> _dupsDe = {};

  // Info do MediaStore (canal nativo): bytes e caminho real por id.
  Map<String, MidiaNativa> _midiaInfo = {};

  // Velocidade e estimativa: bytes por id da sessão + amostras recentes.
  final Map<String, int> _bytesPorId = {};
  final List<(DateTime, int)> _amostras = []; // (quando, bytes concluídos)

  // Sessão atual: pra telemetria e pro diálogo de vitória (1 vez só).
  DateTime? _inicioSessao;
  bool _celebrado = false;
  DateTime _ultimaNotif = DateTime.fromMillisecondsSinceEpoch(0);

  // Integridade: MD5 conferido até este tamanho (acima disso, vale o tamanho).
  static const int _tetoMd5 = 256 * 1024 * 1024;

  int get _bgTotal => _emFila.length;
  int get _bgFeitos => _emFila.where(_enviadosIds.contains).length;

  /// Bytes já seguros no Drive E ainda presentes no celular (o que dá pra
  /// liberar). Cacheado por revisão barata.
  int get _bytesSeguros {
    final chave = '${_enviadosIds.length}|${_items.length}';
    if (chave != _seguroChave) {
      _seguroCache = _items
          .where((m) => _enviadosIds.contains(m.asset.id))
          .fold(0, (s, m) => s + m.bytes);
      _seguroChave = chave;
    }
    return _seguroCache;
  }

  // ---------------------------------------------------------------------------
  // Motor: reconciliar (barato, roda sempre) + alimentar (lento, com trava)
  // ---------------------------------------------------------------------------

  Future<void> _tick() async {
    await _reconciliar();
    await _alimentar();
  }

  Future<void> _reconciliar() async {
    if (_reconciliando || _conta == null || _emFila.isEmpty) return;
    _reconciliando = true;
    try {
      final anterior = Set<String>.of(_emAndamento);
      final ativos = (await BackupService.idsAtivos())
          .where((id) => !_enviadosIds.contains(id))
          .toSet();
      for (final id in anterior.difference(ativos)) {
        final st = await BackupService.statusDe(id);
        if (st == TaskStatus.complete && !_enviadosIds.contains(id)) {
          await _confirmarEnvio(id, null, null);
        }
      }
      _emAndamento
        ..clear()
        ..addAll(ativos);
      _notificarProgresso();
      if (mounted) setState(() {});
    } catch (_) {
      // silencioso: tenta de novo no próximo tick
    } finally {
      _reconciliando = false;
    }
  }

  /// Marca um arquivo como confirmado no Drive: store, contagem, velocidade,
  /// cobertura das duplicatas e limpeza do registro no banco da biblioteca.
  Future<void> _confirmarEnvio(String id, String? fileId, int? bytes,
      {bool contarVelocidade = true}) async {
    if (_enviadosIds.contains(id)) return;
    final b = bytes ?? _bytesPorId[id] ?? 0;
    await _store.marcarEnviado(id, fileId: fileId, bytes: b > 0 ? b : null);
    _enviadosIds.add(id);
    _emAndamento.remove(id);
    if (contarVelocidade && _emFila.contains(id) && b > 0) {
      _amostras.add((DateTime.now(), b));
    }
    await BackupService.limparRegistro(id);
    // Duplicatas exatas cobertas por este arquivo: mesmo fileId no Drive.
    final cobertos = _dupsDe[id];
    if (cobertos != null) {
      for (final cob in cobertos) {
        if (_enviadosIds.contains(cob.id)) continue;
        await _store.marcarEnviado(cob.id,
            fileId: fileId, bytes: cob.bytes > 0 ? cob.bytes : null);
        _enviadosIds.add(cob.id);
      }
    }
    _notificarProgresso();
    _checarConclusao();
  }

  /// A sessão acabou de completar? Celebra (1 vez), registra a telemetria e
  /// limpa a notificação de progresso.
  void _checarConclusao() {
    if (_celebrado || _inicioSessao == null || _emFila.isEmpty) return;
    if (_bgFeitos < _bgTotal) return;
    _celebrado = true;
    Nativo.limparNotificacao();
    BackupService.invalidarListagem(); // subiu coisa nova; a listagem mudou
    var bytesTotal = 0;
    for (final id in _emFila) {
      bytesTotal += _bytesPorId[id] ?? 0;
    }
    _store.registrarSessao({
      'inicio': _inicioSessao!.toIso8601String(),
      'fim': DateTime.now().toIso8601String(),
      'arquivos': _bgTotal,
      'bytes': bytesTotal,
      'falhas': _falhasBg,
      'ultimoErro': _erroBg,
    });
    if (mounted) _mostrarVitoria(_bgTotal, bytesTotal);
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
    if (_emFila.isEmpty || _inicioSessao == null) return;
    final total = _bgTotal;
    final feitos = _bgFeitos;
    if (feitos >= total || _pausado) {
      Nativo.limparNotificacao();
      return;
    }
    final agora = DateTime.now();
    if (agora.difference(_ultimaNotif).inSeconds < 3) return;
    _ultimaNotif = agora;
    var restante = 0;
    for (final id in _emFila) {
      if (!_enviadosIds.contains(id)) restante += _bytesPorId[id] ?? 0;
    }
    final eta = _eta(restante);
    Nativo.notificar(
      'Backup: $feitos de $total',
      eta.isNotEmpty ? '$eta · deixe o app aberto na tomada' : 'Subindo…',
      feitos,
      total,
    );
  }

  Future<void> _alimentar() async {
    if (_alimentando || _conta == null || _pausado || _emFila.isEmpty) return;
    _alimentando = true;
    try {
      final vagas = _janela - _emAndamento.length;
      final lote = <ItemBackup>[];
      while (lote.length < vagas && _pendentes.isNotEmpty) {
        final item = _pendentes.removeAt(0);
        if (item.dup.isNotEmpty ||
            _enviadosIds.contains(item.id) ||
            _emAndamento.contains(item.id) ||
            lote.any((e) => e.id == item.id)) {
          continue;
        }
        lote.add(item);
      }
      if (lote.isEmpty) return;

      await BackupService.garantirSubpastas(_gsi, lote.map((e) => e.pasta));

      for (var i = 0; i < lote.length; i += _concorrenciaPreparo) {
        if (_pausado) {
          _pendentes.insertAll(0, lote.sublist(i));
          break;
        }
        final leva = lote.sublist(i, min(i + _concorrenciaPreparo, lote.length));
        final res = await Future.wait(leva.map((item) async {
          final (ok, erro) =
              await BackupService.enfileirarUm(_gsi, item, soWifi: _soWifi);
          return (item: item, ok: ok, erro: erro);
        }));
        var driveCheio = false;
        for (final r in res) {
          if (r.ok) {
            _emAndamento.add(r.item.id);
            continue;
          }
          if (r.erro == BackupService.erroDriveCheio) {
            _pendentes.insert(0, r.item);
            driveCheio = true;
            continue;
          }
          final t = (_tentativas[r.item.id] ?? 0) + 1;
          _tentativas[r.item.id] = t;
          if (t <= 3) {
            _pendentes.add(r.item); // volta pro fim da fila
          } else {
            _falhasBg++;
            _falhos.add(r.item);
            if (r.erro != null && r.erro!.isNotEmpty) _erroBg = r.erro;
          }
        }
        if (driveCheio) {
          await _pausarPorDriveCheio();
          break;
        }
      }
      if (mounted) setState(() {});
    } catch (_) {
      // silencioso: tenta de novo no próximo tick
    } finally {
      _alimentando = false;
    }
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
    final subindo = _emFila.isNotEmpty && _bgFeitos < _bgTotal;
    if (subindo) return const SizedBox.shrink(); // durante o backup, o banner manda
    final liberaveis = _bytesSeguros;
    final foraDrive = _bytesNoCelular - liberaveis;
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
          Row(
            children: [
              FilledButton(
                onPressed: _abrirSugestoes,
                child: const Text('Liberar espaço'),
              ),
              const SizedBox(width: 8),
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
    final fora =
        _items.where((m) => !_enviadosIds.contains(m.asset.id)).toList();

    List<MediaItem> grupo(bool Function(MediaItem) f) => fora.where(f).toList();
    final grupos = <(String, String, List<MediaItem>)>[];
    void add(String titulo, String desc, List<MediaItem> itens) {
      if (itens.isNotEmpty) grupos.add((titulo, desc, itens));
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
                    final (titulo, desc, itens) = grupos[i];
                    final gb =
                        itens.fold<int>(0, (s, m) => s + m.bytes);
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
                          '$desc · ${itens.length} arquivos · ${_fmt(gb)}'),
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
                          : 'Subir ${selecionados.length} arquivos (${_fmt(bytes)})'),
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
    final escolha = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Não cabe tudo no Drive'),
        content: Text(
            'Você marcou ${_fmt(precisa)}, mas só tem ${_fmt(livre)} livres.\n\n'
            'Posso subir só o que cabe: ${cabem.length} arquivos (${_fmt(soma)}), começando pelos maiores. O resto fica pra depois que você liberar espaço.'),
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

  Future<void> _reconhecerBackupAntigo() async {
    if (_enviadosIds.isNotEmpty) return;
    final noDrive = await BackupService.listarNoDrive(_gsi);
    if (noDrive == null || noDrive.isEmpty) return;
    final porChave = <String, ArquivoDrive>{};
    for (final a in noDrive) {
      porChave['${a.nome}|${a.pasta}|${a.bytes}'] = a;
    }
    var achados = 0;
    for (final m in _items) {
      final chave = '${m.asset.title ?? ''}|${m.pasta}|${m.bytes}';
      final a = porChave[chave];
      if (a == null) continue;
      await _store.marcarEnviado(m.asset.id, fileId: a.fileId, bytes: m.bytes);
      _enviadosIds.add(m.asset.id);
      achados++;
    }
    await _store.gravarAgora();
    if (achados > 0 && mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Achei $achados arquivos de um backup anterior no Drive. Eles não sobem de novo.')));
    }
  }

  Future<void> _subir() async {
    if (_conta == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Entre com o Google primeiro.')));
      return;
    }

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

    await _reconhecerBackupAntigo();

    final selecionados = _selected
        .map((m) => ItemBackup(m.asset.id, m.asset.title ?? 'sem nome', m.pasta,
            path: m.path, bytes: m.bytes))
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
    var mergedItens = mapa.values.map(ItemBackup.fromMap).toList();

    var pendentesItens =
        mergedItens.where((it) => !_enviadosIds.contains(it.id)).toList();
    if (pendentesItens.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Tudo que você marcou já está no Drive.')));
      return;
    }

    // Duplicatas exatas (mesmo nome + mesmo tamanho, clássico do WhatsApp):
    // sobe 1, as outras são cobertas pelo mesmo arquivo do Drive.
    final porChaveDup = <String, ItemBackup>{};
    var duplicatas = 0;
    pendentesItens = pendentesItens.map((it) {
      if (it.bytes <= 0 || it.dup.isNotEmpty) return it;
      final chave = '${it.titulo}|${it.bytes}';
      final principal = porChaveDup[chave];
      if (principal == null) {
        porChaveDup[chave] = it;
        return it;
      }
      duplicatas++;
      return ItemBackup(it.id, it.titulo, it.pasta,
          path: it.path, bytes: it.bytes, dup: principal.id);
    }).toList();

    // Checa espaço: só o que de fato sobe (duplicata coberta não conta).
    final precisa = pendentesItens
        .where((it) => it.dup.isEmpty)
        .fold<int>(0, (s, it) => s + it.bytes);
    final livre = await BackupService.espacoLivre(_gsi);
    if (livre != null && precisa > livre) {
      final soSobem =
          pendentesItens.where((it) => it.dup.isEmpty).toList();
      final aparados = await _apararPraCaber(soSobem, precisa, livre);
      if (aparados == null || aparados.isEmpty) return;
      final idsAparados = aparados.map((e) => e.id).toSet();
      // Ficam: os aparados + as duplicatas cujo principal ficou.
      pendentesItens = pendentesItens
          .where((it) => it.dup.isEmpty
              ? idsAparados.contains(it.id)
              : idsAparados.contains(it.dup))
          .toList();
    }
    mergedItens = [
      ...mergedItens.where((it) => _enviadosIds.contains(it.id)),
      ...pendentesItens,
    ];

    await _prepararJobGrande(
        pendentesItens.where((it) => it.dup.isEmpty).fold<int>(0, (s, it) => s + it.bytes));

    // Maiores primeiro: libera mais espaço mais cedo.
    pendentesItens.sort((a, b) => b.bytes.compareTo(a.bytes));

    await _store.salvarJob(mergedItens.map((e) => e.toMap()).toList());
    await _store.setPausado(false);
    BackupService.invalidarListagem();

    if (mounted) {
      setState(() {
        _pausado = false;
        _driveCheio = false;
        _falhasBg = 0;
        _falhos.clear();
        _erroBg = null;
        _tentativas.clear();
        _amostras.clear();
        _inicioSessao = DateTime.now();
        _celebrado = false;
        _emFila
          ..clear()
          ..addAll(mergedItens.map((e) => e.id));
        _bytesPorId
          ..clear()
          ..addEntries(mergedItens.map((e) => MapEntry(e.id, e.bytes)));
        _dupsDe.clear();
        for (final it in mergedItens) {
          if (it.dup.isNotEmpty) {
            _dupsDe.putIfAbsent(it.dup, () => []).add(it);
          }
        }
        _pendentes
          ..clear()
          ..addAll(pendentesItens.where((it) => it.dup.isEmpty));
      });
      // Duplicata cujo principal JÁ está no Drive: cobre agora, senão a
      // contagem da sessão nunca fecharia esperando um upload que não existe.
      for (final entry in _dupsDe.entries) {
        if (!_enviadosIds.contains(entry.key)) continue;
        final fileId = _store.envioDe(entry.key)?.fileId;
        for (final cob in entry.value) {
          if (_enviadosIds.contains(cob.id)) continue;
          await _store.marcarEnviado(cob.id,
              fileId: fileId, bytes: cob.bytes > 0 ? cob.bytes : null);
          _enviadosIds.add(cob.id);
        }
      }
      final msgDup = duplicatas > 0
          ? ' $duplicatas duplicatas sobem 1 vez só (poupa Drive).'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Backup começou. Deixe o app aberto na tomada pra ir até o fim.$msgDup')));
    }

    _tick();
  }

  Future<void> _parar() async {
    await _store.setPausado(true);
    Nativo.limparNotificacao();
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
    if (mounted) {
      setState(() {
        _pausado = false;
        _driveCheio = false;
        _erroBg = null;
      });
    }
    final job = await _store.job();
    await _retomarJanela(job);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Retomando de onde parou.')));
    }
  }

  Future<void> _tentarFalhosDeNovo() async {
    if (_falhos.isEmpty) return;
    setState(() {
      for (final it in _falhos) {
        _tentativas.remove(it.id);
        _pendentes.add(it);
      }
      _falhos.clear();
      _falhasBg = 0;
      _erroBg = null;
    });
    _tick();
  }

  // ---------------------------------------------------------------------------
  // Apagar do celular (com conferência real no Drive)
  // ---------------------------------------------------------------------------

  Future<void> _apagarEnviados() async {
    final idsNoCelular = _items.map((m) => m.asset.id).toSet();
    final candidatos = _enviadosIds.where(idsNoCelular.contains).toList();
    if (candidatos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Nada confirmado no Drive ainda. Suba antes de apagar.')));
      return;
    }

    final bytes = _items
        .where((m) => candidatos.contains(m.asset.id))
        .fold<int>(0, (s, m) => s + m.bytes);
    final confirma = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Apagar do celular'),
        content: Text(
            'Apagar ${candidatos.length} arquivos (${_fmt(bytes)})?\n\nAntes de apagar, o app confere um a um no Drive. O que não estiver conferido fica no celular.\n\nO Android vai pedir confirmação em algumas levas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Conferir e apagar')),
        ],
      ),
    );
    if (confirma != true) return;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(child: Text('Conferindo no Drive…')),
        ]),
      ),
    );
    final noDrive = await BackupService.listarNoDrive(_gsi);
    if (mounted) Navigator.pop(context); // fecha o "conferindo"
    if (noDrive == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Sem rede pra conferir no Drive. Sem conferência, nada é apagado.')));
      }
      return;
    }
    final tamPorFileId = <String, int>{};
    final porChave = <String, int>{}; // nome|pasta|bytes -> quantos existem
    for (final a in noDrive) {
      tamPorFileId[a.fileId] = a.bytes;
      final chave = '${a.nome}|${a.pasta}|${a.bytes}';
      porChave[chave] = (porChave[chave] ?? 0) + 1;
    }
    final itemPorId = {for (final m in _items) m.asset.id: m};
    final verificados = <String>[];
    var naoConferidos = 0;
    for (final id in candidatos) {
      final info = _store.envioDe(id);
      final item = itemPorId[id];
      final fid = info?.fileId;
      final ibytes = info?.bytes;
      var ok = false;
      if (fid != null) {
        final tam = tamPorFileId[fid];
        ok = tam != null && (ibytes == null || tam == ibytes);
      } else if (item != null) {
        final chave = '${item.asset.title ?? ''}|${item.pasta}|${item.bytes}';
        final quantos = porChave[chave] ?? 0;
        if (quantos > 0) {
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Não consegui conferir nenhum arquivo no Drive. Nada foi apagado.')));
      }
      return;
    }

    const tamLote = 800;
    final List<String> apagadosAll = [];
    for (var i = 0; i < verificados.length; i += tamLote) {
      final chunk = verificados.sublist(i, min(i + tamLote, verificados.length));
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
      _ordenadoCache = null;
      _seguroChave = '';
      _bytesNoCelular = _items.fold(0, (s, m) => s + m.bytes);
      final Map<String, List<MediaItem>> grupos = {};
      for (final it in _items) {
        grupos.putIfAbsent(it.pasta, () => []).add(it);
      }
      _pastas = grupos.entries.map((e) => Pasta(e.key, e.value)).toList()
        ..sort((a, b) => b.bytes.compareTo(a.bytes));
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(naoConferidos > 0
            ? 'Apagados ${setApagados.length}. Outros $naoConferidos não conferiram no Drive e ficaram no celular.'
            : 'Apagados ${setApagados.length} do celular.')));
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
    }
  }

  Future<void> _iniciarBackupEngine() async {
    await _store.init(await Nativo.dirDados()); // idempotente

    await BackupService.configurar();
    _sub = FileDownloader().updates.listen(_onUpdate);
    await BackupService.iniciarMotor();

    final concluidos = await BackupService.concluidosNoBanco();
    for (final id in concluidos) {
      await _store.marcarEnviado(id);
      await BackupService.limparRegistro(id);
    }
    await _store.gravarAgora();

    if (await _store.precisaLimparFila()) {
      await BackupService.limparFilaLegada();
      await _store.marcarFilaLimpa();
    }

    try {
      final conta = await _gsi.signInSilently();
      if (conta != null && mounted) setState(() => _conta = conta);
    } catch (_) {}

    final enviados = await _store.enviados();
    final job = await _store.job();
    final pausado = await _store.pausado();
    final soWifi = await _store.soWifi();
    if (mounted) {
      setState(() {
        _enviadosIds = enviados;
        _pausado = pausado;
        _soWifi = soWifi;
        if (job.isNotEmpty) {
          _emFila
            ..clear()
            ..addAll(job.map((m) => m['id'] ?? ''));
          _bytesPorId
            ..clear()
            ..addEntries(job.map((m) => MapEntry(
                m['id'] ?? '', int.tryParse(m['bytes'] ?? '') ?? 0)));
        }
      });
    }
    _retomarJanela(job);
  }

  void _onUpdate(TaskUpdate update) async {
    if (update is! TaskStatusUpdate ||
        update.task.group != BackupService.grupo) {
      return;
    }
    final id = update.task.taskId;
    if (update.status == TaskStatus.complete) {
      final (fileId, bytes, md5Drive) =
          BackupService.extrairArquivoDaResposta(update.responseBody);
      final meta = MetaTarefa.decodificar(update.task.metaData);
      final b = bytes ?? meta.bytes;

      // Integridade: confere o MD5 local contra o que o Drive calculou.
      // Só até 256 MB (acima disso o custo de reler o arquivo não compensa;
      // a conferência de tamanho segue valendo). Divergiu = refaz o upload.
      if (md5Drive != null && b > 0 && b <= _tetoMd5) {
        try {
          final caminho = await update.task.filePath();
          final md5Local = await Nativo.md5(caminho);
          if (md5Local != null && md5Local != md5Drive) {
            await BackupService.apagarCopiaDeCache(update.task);
            if (fileId != null) BackupService.apagarNoDrive(_gsi, fileId);
            final t = (_tentativas[id] ?? 0) + 1;
            _tentativas[id] = t;
            final item = ItemBackup(id, update.task.filename, meta.pasta,
                bytes: meta.bytes);
            if (t <= 3) {
              _pendentes.add(item);
              _erroBg = 'Um arquivo chegou diferente no Drive; refazendo.';
            } else {
              _falhasBg++;
              _falhos.add(item);
              _erroBg = '"${update.task.filename}" chegou corrompido 3 vezes.';
            }
            if (mounted) setState(() {});
            _tick();
            return;
          }
        } catch (_) {
          // sem MD5 não bloqueia: a conferência de tamanho continua valendo
        }
      }

      await _confirmarEnvio(id, fileId, bytes);
      await BackupService.apagarCopiaDeCache(update.task);
      if (mounted) setState(() {});
      _tick();
    } else if (update.status == TaskStatus.failed ||
        update.status == TaskStatus.notFound) {
      await BackupService.apagarCopiaDeCache(update.task);
      final exc = update.exception;
      final quota = exc is TaskHttpException && exc.httpResponseCode == 403;
      if (quota) {
        final meta = MetaTarefa.decodificar(update.task.metaData);
        _pendentes.insert(
            0,
            ItemBackup(id, update.task.filename, meta.pasta,
                bytes: meta.bytes));
        await _pausarPorDriveCheio();
        return;
      }
      final t = (_tentativas[id] ?? 0) + 1;
      _tentativas[id] = t;
      final meta = MetaTarefa.decodificar(update.task.metaData);
      final item = ItemBackup(id, update.task.filename, meta.pasta,
          bytes: meta.bytes);
      if (!_pausado &&
          t <= 3 &&
          _emFila.contains(id) &&
          !_enviadosIds.contains(id)) {
        _pendentes.add(item);
      } else if (mounted) {
        setState(() {
          _falhasBg++;
          _falhos.add(item);
          final desc = update.exception?.description;
          if (desc != null && desc.isNotEmpty) _erroBg = desc;
        });
      }
      _tick();
    }
  }

  Future<void> _retomarJanela(List<Map<String, String>> job) async {
    if (job.isEmpty || _conta == null || _pausado) return;
    await Future.delayed(const Duration(seconds: 3));
    final enviados = await _store.enviados(); // leitura fresca
    final itens = job.map(ItemBackup.fromMap).toList();

    // Reconstrói o mapa de duplicatas e cobre as que o principal já pagou.
    _dupsDe.clear();
    for (final it in itens) {
      if (it.dup.isNotEmpty) _dupsDe.putIfAbsent(it.dup, () => []).add(it);
    }
    for (final entry in _dupsDe.entries) {
      if (!enviados.contains(entry.key)) continue;
      final fileId = _store.envioDe(entry.key)?.fileId;
      for (final cob in entry.value) {
        if (enviados.contains(cob.id)) continue;
        await _store.marcarEnviado(cob.id,
            fileId: fileId, bytes: cob.bytes > 0 ? cob.bytes : null);
        enviados.add(cob.id);
        _enviadosIds.add(cob.id);
      }
    }

    final pendentes = itens
        .where((it) =>
            it.id.isNotEmpty &&
            it.dup.isEmpty &&
            !enviados.contains(it.id))
        .toList()
      ..sort((a, b) => b.bytes.compareTo(a.bytes)); // maiores primeiro
    if (!mounted) return;
    if (pendentes.isEmpty) return;
    final (ok, _) = await BackupService.prepararContexto(_gsi);
    if (!ok) return;
    if (!mounted) return;
    setState(() {
      _inicioSessao ??= DateTime.now(); // sessão retomada conta como ativa
      _pendentes
        ..clear()
        ..addAll(pendentes);
    });
    _tick();
  }

  // ---------------------------------------------------------------------------
  // Galeria
  // ---------------------------------------------------------------------------

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

    final infoFut = Nativo.midias();

    const pagina = 1000;
    final List<MediaItem> items = [];
    for (var inicio = 0; inicio < count; inicio += pagina) {
      final assets = await all.getAssetListRange(
          start: inicio, end: min(inicio + pagina, count));
      items.addAll(
          [for (final a in assets) MediaItem(a, 0, _nomePasta(a))]);
      if (inicio == 0 && mounted) {
        setState(() {
          _loading = false;
          _items = items;
          _calculando = true; // ainda paginando/medindo; o setState final corrige
          _lidos = 0;
          _status = 'Carregando galeria…';
        });
      }
    }

    _midiaInfo = await infoFut;
    final cacheFallback = await _store.tamanhos();
    for (final it in items) {
      final info = _midiaInfo[it.asset.id];
      if (info != null) {
        if (info.bytes > 0) it.bytes = info.bytes;
        it.path = info.caminho;
      }
      if (it.bytes == 0) {
        final c = cacheFallback[it.asset.id];
        if (c != null) it.bytes = c;
      }
    }
    final Map<String, List<MediaItem>> grupos = {};
    for (final it in items) {
      grupos.putIfAbsent(it.pasta, () => []).add(it);
    }
    final pastas = grupos.entries.map((e) => Pasta(e.key, e.value)).toList()
      ..sort((a, b) => b.bytes.compareTo(a.bytes));
    final faltam = items.where((it) => it.bytes == 0).length;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = items;
      _pastas = pastas;
      _status = '${items.length} arquivos';
      _ordenadoCache = null;
      _seguroChave = '';
      _bytesNoCelular = items.fold(0, (s, m) => s + m.bytes);
      _calculando = faltam > 0;
      _lidos = items.length - faltam;
    });
    if (faltam > 0) _calcularTamanhosFallback();
  }

  Future<void> _calcularTamanhosFallback() async {
    final pendentes = _items.where((it) => it.bytes == 0).toList();
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
    if (_emAndamento.isEmpty) {
      try {
        await PhotoManager.clearFileCache();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _lidos = _items.length;
      _calculando = false;
      _ordenadoCache = null;
      _seguroChave = '';
      _bytesNoCelular = _items.fold(0, (s, m) => s + m.bytes);
      _pastas.sort((a, b) => b.bytes.compareTo(a.bytes));
    });
  }

  String _nomePasta(AssetEntity a) {
    final rp = a.relativePath ?? '';
    final partes = rp.split('/').where((p) => p.isNotEmpty).toList();
    return partes.isEmpty ? 'Outros' : partes.last;
  }

  List<MediaItem> get _itensOrdenados {
    final ordemReal = (_ordem == 'data' || _calculando) ? 'data' : 'tamanho';
    final chave = '$ordemReal|${_items.length}';
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

  double get _velocidade {
    final agora = DateTime.now();
    _amostras.removeWhere((a) => agora.difference(a.$1).inSeconds > 300);
    if (_amostras.length < 2) return 0;
    final bytes = _amostras.fold<int>(0, (s, a) => s + a.$2);
    final janela = agora.difference(_amostras.first.$1).inSeconds;
    if (janela < 5) return 0;
    return bytes / janela;
  }

  String _eta(int bytesRestantes) {
    final v = _velocidade;
    if (v <= 0 || bytesRestantes <= 0) return '';
    final s = (bytesRestantes / v).round();
    if (s < 90) return '~1 min restante';
    if (s < 3600) return '~${(s / 60).round()} min restantes';
    final h = s ~/ 3600;
    final m = ((s % 3600) / 60).round();
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

    var bytesTotal = 0;
    var bytesFeitos = 0;
    for (final id in _emFila) {
      final b = _bytesPorId[id] ?? 0;
      bytesTotal += b;
      if (_enviadosIds.contains(id)) bytesFeitos += b;
    }
    final pct = bytesTotal > 0
        ? bytesFeitos / bytesTotal
        : (total == 0 ? 0.0 : feitos / total);
    final faltam = total - feitos;
    final eta = (!pronto && !_pausado) ? _eta(bytesTotal - bytesFeitos) : '';
    final vel = _velocidade;
    final liberaveis = _bytesSeguros;

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
              if (pronto && liberaveis > 0)
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
              value: pct,
            ),
          ),
          if (!pronto)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  _pausado
                      ? 'Pausado · faltam $faltam · toque em Retomar pra continuar'
                      : 'Subindo agora: ${_emAndamento.length} · na fila: ${_pendentes.length}'
                          '${eta.isNotEmpty ? ' · $eta' : ''}'
                          '${vel > 0 ? ' · ${_fmt(vel.round())}/s' : ''}',
                  style: const TextStyle(fontSize: 12, color: _inkMuted)),
            ),
          if (!pronto && !_pausado)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                  'Com o app fechado sobem só os que já estão na fila do Android. Pra ir até o fim, deixe aberto na tomada.',
                  style: TextStyle(fontSize: 12, color: _inkMuted)),
            ),
          if (_falhasBg > 0 || _erroBg != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _erroBg != null
                          ? 'Problema: $_erroBg'
                          : '$_falhasBg arquivo(s) falharam.',
                      style:
                          const TextStyle(fontSize: 12, color: Color(0xFFB00020)),
                    ),
                  ),
                  if (_falhos.isNotEmpty && !_driveCheio)
                    TextButton(
                        onPressed: _tentarFalhosDeNovo,
                        child: Text('Tentar de novo (${_falhos.length})')),
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
                      item: item,
                      selecionado: _selected.contains(item),
                      noDrive: _enviadosIds.contains(item.asset.id),
                      tamanho: _fmt(item.bytes),
                      onTap: () => _toggle(item),
                      onLongPress: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => PreviewPage(item.asset))),
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
              final subiu = p.itens
                  .where((it) => _enviadosIds.contains(it.asset.id))
                  .length;
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

/// Miniatura com cache LRU: o mesmo Uint8List devolvido faz o Flutter
/// reaproveitar a decodificação, sem refazer thumb a cada rebuild.
class _Thumb extends StatelessWidget {
  final String id;
  final AssetEntity asset;
  final bool isVideo;
  const _Thumb({required this.id, required this.asset, required this.isVideo});

  @override
  Widget build(BuildContext context) {
    final emCache = _ThumbCache.pegar(id);
    if (emCache != null) {
      return Image.memory(emCache, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return FutureBuilder<Uint8List?>(
      future: asset
          .thumbnailDataWithSize(const ThumbnailSize(200, 200))
          .then((b) {
        if (b != null) _ThumbCache.guardar(id, b);
        return b;
      }),
      builder: (c, snap) {
        if (snap.data == null) {
          return Container(
            color: Colors.black12,
            child: Icon(isVideo ? Icons.videocam : Icons.image,
                color: _inkMuted),
          );
        }
        return Image.memory(snap.data!,
            fit: BoxFit.cover, gaplessPlayback: true);
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
