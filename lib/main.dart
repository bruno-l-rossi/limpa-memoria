import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:background_downloader/background_downloader.dart';
import 'upload_store.dart';
import 'backup_service.dart';
import 'nativo.dart';
import 'formatos.dart';
import 'selecao_backup.dart';
import 'verificacao_apagar.dart';
import 'telemetria.dart';
import 'mensagens.dart';
import 'sugestoes.dart';
import 'pastas.dart';
import 'manutencao_drive.dart';
import 'selecao.dart';
import 'diario.dart';
import 'motor_nativo.dart';

part 'app_midia.dart';
part 'app_paginas.dart';
part 'app_tema.dart';
part 'home_drive.dart';
part 'home_galeria.dart';
part 'home_motor.dart';
part 'home_nativo.dart';
part 'home_telas.dart';

void main() => runApp(const MyApp());

const String _versao = '1.9.0';

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: _temaApp,
        builder: (_, tema, _) => MaterialApp(
          title: 'Limpa Memória',
          debugShowCheckedModeBanner: false,
          theme: _tema(Brightness.light),
          darkTheme: _tema(Brightness.dark),
          themeMode: switch (tema) {
            'claro' => ThemeMode.light,
            'escuro' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          // Acerta as cores (_escuro) com o tema em uso antes das telas.
          builder: (ctx, child) {
            _escuro = Theme.of(ctx).brightness == Brightness.dark;
            return child ?? const SizedBox.shrink();
          },
          home: const HomePage(),
        ),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

// Constantes do motor (eram static do State; extensões não enxergam
// static sem o nome da classe).
// Janela deslizante guiada pelo banco da biblioteca (a fonte da verdade).
// Janela por arquivos E por bytes (rodada 14): 40 fotos de 2 MB eram um
// colchão de 80 MB; 40 vídeos, dezenas de GB presos na fila do Android.
const int _janelaMax = 80;
const int _janelaMin = 8;
const int _janelaBytes = 4 * 1024 * 1024 * 1024;
const int _concorrenciaPreparo = 6;
const _prefixoJa = 'ja-no-drive:';
// Integridade: MD5 conferido até este tamanho (acima disso, vale o tamanho).
const int _tetoMd5 = 4 * 1024 * 1024 * 1024; // A-08 (rodada 19): era 256 MB
const int _pequeno = 8 * 1024 * 1024;

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  bool _loading = true;
  String _status = 'Carregando...';
  List<MediaItem> _items = [];
  List<Pasta> _pastas = [];
  // Rodada 18: soma e contagem por pasta feitas na hora (A-16).
  final Selecao<MediaItem> _selected =
      Selecao(bytesDe: (m) => m.bytes, grupoDe: (m) => m.pasta);
  String _ordem = 'tamanho'; // 'tamanho' ou 'data'
  String _filtro = 'todos'; // 'todos' | 'drive' | 'foradrive'
  String _tipo = 'todos'; // 'todos' | 'fotos' | 'videos'
  bool _permissaoNegada = false;

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
  int _cPequenosRestantes = 0;

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
  final Map<String, String> _motivoFalha = {}; // id -> motivo (lista de falhas)
  String? _erroBg; // último motivo de erro, pra mostrar na tela
  bool _pausado = false; // backup pausado (pelo usuário ou por Drive cheio)
  bool _driveCheio = false; // pausa automática por cota estourada
  bool _soWifi = false; // subir só no wifi (escolha do usuário)
  bool _lixeira = false; // rodada 18: apagar manda pra lixeira (30 dias)
  int _sdk = 0; // versão do Android (a lixeira só existe no 11+, API 30)
  bool _dicaAbertoVista = true; // dica "app aberto na tomada" dispensada
  // Rodada 19 (F4): motor nativo, que sobe com o app fechado (home_nativo).
  bool _motorFechado = false; // ajuste "Subir com o app fechado"
  bool _nativoRecusado = false; // não deu nesta sessão: segue no antigo
  bool _nativoAutorizado = false; // Google liberou o token sem tela
  bool _emPrimeiroPlano = true; // o UIDT só liga com o app na tela
  ArquivosMotor? _arqMotor;
  final Map<String, ItemNativo> _noNativo = {}; // entregues ao motor nativo
  EstadoNativo? _estadoNativo;
  int _offsetNativo = 0;
  int _geracaoNativo = 0; // geração do resultados.jsonl (rodada 20)
  bool _offsetNativoLido = false;
  bool _importandoNativo = false;
  DateTime? _semVidaDesde;
  Timer? _pollNativo;
  StreamSubscription<TaskUpdate>? _sub;

  final ListQueue<ItemBackup> _pendentes = ListQueue(); // não enfileirados
  final Set<String> _naFila = {}; // ids em _pendentes (sem repetição)
  final Set<String> _emAndamento = {}; // ativos no motor agora
  final Set<String> _preparando = {}; // saíram da fila, ainda abrindo sessão
  final Set<String> _processando = {}; // conclusão sendo conferida (MD5)
  // Motor novo (rodada 15, experimental): arquivos grandes sobem em partes
  // pelo próprio app, com retomada de onde parou.
  final Map<String, int> _tentativas = {}; // re-tentativas por id
  final Map<String, int> _tentativasRede = {}; // quedas de rede por id
  final Set<String> _corrompidos = {}; // chegaram diferentes: nunca "achar"
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
  bool _acessoParcial = false; // Android 14+: "selecionar fotos" (vê só parte)
  bool _recarregando = false;
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
  int _arquivosSessao = 0; // idem, em arquivos (ETA de fotos pequenas)

  // Sessão atual: pra telemetria e pro diálogo de vitória (1 vez só).
  DateTime? _inicioSessao;
  bool _celebrado = false;
  bool _fimRegistrado = false;
  DateTime _ultimaNotif = DateTime.fromMillisecondsSinceEpoch(0);

  // Números da sessão por faixa de tamanho (diagnóstico local).
  final Telemetria _telemetria = Telemetria();

  void _mudou() => _rev++;

  /// setState pras extensões (home_*.dart): o setState é protegido e só
  /// vale dentro do próprio State.
  void _set(VoidCallback f) => setState(f);

  /// Diário de eventos do motor (arquivo local, nada sai do celular sem o
  /// usuário tocar em Compartilhar). É o que transforma "travou" em dado.
  void _ev(String texto) => _store.registrarEvento(texto);

  void _avisar(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
  }

  // MD5 local por id (cache da execução: o arquivo não muda enquanto o app
  // está aberto; se mudar, o tamanho muda e a conferência pega).
  final Map<String, String> _md5Cache = {};

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _tick());
    // Motor do app fechado: lê o progresso dele a cada 3 s com o app aberto.
    _pollNativo = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_noNativo.isNotEmpty) _importarNativo();
    });
  }

  /// Decide entre onboarding e o app. O motor e a galeria só sobem depois que
  /// o onboarding foi visto (é ele que explica as permissões que vêm a seguir).
  Future<void> _boot() async {
    final dir = await Nativo.dirDados();
    await _store.init(dir);
    registrarNoDiario = _ev; // falhas engolidas no motor vão pro diário
    _temaApp.value = await _store.texto(UploadStore.kTema) ?? 'sistema';
    if (dir != null && dir.isNotEmpty) {
      _arqMotor = ArquivosMotor(dir);
    }
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
    _pollNativo?.cancel();
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
      _emPrimeiroPlano = false;
      _store.gravarAgora();
    } else if (state == AppLifecycleState.resumed) {
      _emPrimeiroPlano = true;
      _tick(); // voltou pro app: sincroniza na hora
    }
  }

  String _fmt(int bytes) => fmtBytes(bytes);
  String _milhar(int n) => milhar(n);

  @override
  Widget build(BuildContext context) {
    _dependerDoTema(context);
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
          bottom: TabBar(
            labelColor: _ink,
            unselectedLabelColor: _inkMuted,
            indicatorColor: _actionBlue,
            tabs: [Tab(text: 'Mídias'), Tab(text: 'Pastas')],
          ),
          actions: [
            _botaoConta(),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Ajustes',
              onPressed: _abrirAjustes,
            ),
          ],
        ),
        body: _permissaoNegada
            ? _telaPermissao()
            : _loading
                ? _telaCarregando()
                : _items.isEmpty
                    ? _telaVazia()
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
                        style: TextStyle(color: _inkMuted, fontSize: 14),
                      ),
                    ),
                  ],
                  _avisoAcessoParcial(),
                  _cardMissao(),
                  _bannerBackup(),
                  Expanded(
                    child: TabBarView(children: [_abaMidias(), _abaPastas()]),
                  ),
                ],
              ),
        bottomNavigationBar: _items.isEmpty ? null : _barraSubir(),
      ),
    );
  }

  bool _dicaMostrada = false;

}

