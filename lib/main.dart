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

  // Ordenação cacheada: ordenar 19 mil itens a cada build (e tem build a cada
  // conclusão e a cada tick de 15s) era jank de horas. Recalcula só quando a
  // ordem ou os dados mudam; o filtro em cima é O(n) barato.
  List<MediaItem>? _ordenadoCache;
  String _ordenadoChave = '';

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
  //
  // Rodada 8: janela de 6 pra 40. A janela pequena tinha um custo escondido:
  // se o Android mata o app, só o que já está no motor termina. Com 40, um
  // kill de madrugada ainda deixa horas de upload andando sozinho. O preparo
  // continua em levas de 6 por vez pra não abrir 40 arquivos de uma vez.
  static const int _janela = 40;
  static const int _concorrenciaPreparo = 6;
  final List<ItemBackup> _pendentes = []; // ainda não enfileirados
  final Set<String> _emAndamento = {}; // ativos no motor agora (só pra exibir)
  final Map<String, int> _tentativas = {}; // re-tentativas por id
  bool _reconciliando = false; // trava de reentrância (parte barata)
  bool _alimentando = false; // trava de reentrância (parte lenta)
  Timer? _poll; // sincroniza com o banco a cada 15s

  // Info do MediaStore (canal nativo): bytes e caminho real por id.
  Map<String, MidiaNativa> _midiaInfo = {};

  // Velocidade e estimativa: bytes por id da sessão + amostras recentes.
  final Map<String, int> _bytesPorId = {};
  final List<(DateTime, int)> _amostras = []; // (quando, bytes concluídos)

  int get _bgTotal => _emFila.length;
  int get _bgFeitos => _emFila.where(_enviadosIds.contains).length;

  // ---------------------------------------------------------------------------
  // Motor: reconciliar (barato, roda sempre) + alimentar (lento, com trava)
  // ---------------------------------------------------------------------------

  /// Tick do motor: reconcilia com o banco e depois repõe a janela. Separados
  /// de propósito: antes uma trava única segurava a reconciliação enquanto um
  /// preparo lento rodava, e a janela secava esperando o próximo tick.
  Future<void> _tick() async {
    await _reconciliar();
    await _alimentar();
  }

  /// Pergunta ao banco da biblioteca o que está ativo e o que concluiu, e
  /// atualiza a contagem. Não depende de capturar todo evento ao vivo (que se
  /// perde em job longo): o banco é a fonte da verdade.
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
      if (mounted) setState(() {});
    } catch (_) {
      // silencioso: tenta de novo no próximo tick
    } finally {
      _reconciliando = false;
    }
  }

  /// Marca um arquivo como confirmado no Drive: store (linha em append),
  /// contagem, velocidade e limpeza do registro no banco da biblioteca.
  Future<void> _confirmarEnvio(String id, String? fileId, int? bytes) async {
    if (_enviadosIds.contains(id)) return;
    final b = bytes ?? _bytesPorId[id] ?? 0;
    await _store.marcarEnviado(id, fileId: fileId, bytes: b > 0 ? b : null);
    _enviadosIds.add(id);
    _emAndamento.remove(id);
    if (_emFila.contains(id) && b > 0) {
      _amostras.add((DateTime.now(), b));
    }
    // Banco da biblioteca não precisa mais desse registro (o nosso store é a
    // fonte). Sem essa limpeza o banco cresce sem limite e o boot fica lento.
    await BackupService.limparRegistro(id);
  }

  /// Repõe a janela: pega pendentes, prepara em levas de 6 e enfileira.
  Future<void> _alimentar() async {
    if (_alimentando || _conta == null || _pausado || _emFila.isEmpty) return;
    _alimentando = true;
    try {
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
      if (lote.isEmpty) return;

      // Pré-cria as subpastas da leva ANTES do paralelo, senão dois uploads
      // da mesma pasta nova criariam a pasta duas vezes no Drive.
      await BackupService.garantirSubpastas(_gsi, lote.map((e) => e.pasta));

      // Prepara em levas de 6: paralelo o bastante pra rede não ficar ociosa,
      // sem abrir dezenas de arquivos grandes ao mesmo tempo.
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

  /// Drive sem espaço no meio do job: pausa sozinho com recado claro, em vez
  /// de queimar retentativas arquivo por arquivo com erro genérico.
  Future<void> _pausarPorDriveCheio() async {
    await _store.setPausado(true);
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

  /// Backup grande: sugere tomada e pede a isenção de bateria do Android, que
  /// é o que impede o Doze de matar o job de madrugada.
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

  /// Não cabe tudo no Drive: oferece subir só o que cabe, priorizando os
  /// maiores (liberam mais espaço no celular). Devolve a lista aparada, ou
  /// null se o usuário cancelou.
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

  /// Reinstalou o app? O store zera, mas o backup continua no Drive. O escopo
  /// drive.file enxerga o que o próprio app criou, então dá pra reconhecer o
  /// que já subiu (por nome + pasta + tamanho) e não duplicar nada.
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

    // Prepara o contexto (token + pasta principal) logo, porque a
    // reconciliação de backup antigo também precisa dele.
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

    // Primeira vez com store vazio: confere se já existe backup no Drive
    // (caso reinstalação) antes de decidir o que sobe.
    await _reconhecerBackupAntigo();

    // Os selecionados viram itens (com caminho real e bytes do MediaStore).
    // A sessão (job) é MESCLADA, nunca reescrita menor: é o que mantém o
    // total da barra estável do começo ao fim.
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

    // O que ainda falta subir nesta sessão.
    var pendentesItens =
        mergedItens.where((it) => !_enviadosIds.contains(it.id)).toList();
    if (pendentesItens.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Tudo que você marcou já está no Drive.')));
      return;
    }

    // Checa espaço. Se não cabe, oferece subir só o que cabe.
    final precisa = pendentesItens.fold<int>(0, (s, it) => s + it.bytes);
    final livre = await BackupService.espacoLivre(_gsi);
    if (livre != null && precisa > livre) {
      final aparados = await _apararPraCaber(pendentesItens, precisa, livre);
      if (aparados == null || aparados.isEmpty) return;
      pendentesItens = aparados;
      final idsAparados = aparados.map((e) => e.id).toSet();
      mergedItens = mergedItens
          .where((it) =>
              _enviadosIds.contains(it.id) || idsAparados.contains(it.id))
          .toList();
    }

    // Job grande: tomada + isenção de bateria.
    await _prepararJobGrande(pendentesItens.fold<int>(0, (s, it) => s + it.bytes));

    await _store.salvarJob(mergedItens.map((e) => e.toMap()).toList());
    await _store.setPausado(false);

    if (mounted) {
      setState(() {
        _pausado = false;
        _driveCheio = false;
        _falhasBg = 0;
        _falhos.clear();
        _erroBg = null;
        _tentativas.clear();
        _amostras.clear();
        _emFila
          ..clear()
          ..addAll(mergedItens.map((e) => e.id));
        _bytesPorId
          ..clear()
          ..addEntries(mergedItens.map((e) => MapEntry(e.id, e.bytes)));
        _pendentes
          ..clear()
          ..addAll(pendentesItens);
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Backup começou. Deixe o app aberto na tomada pra ir até o fim sem parar.')));
    }

    _tick();
  }

  /// Para o backup: deixa de alimentar a janela (o que já estava subindo
  /// termina sozinho) e limpa os pendentes. O job fica salvo, então o Retomar
  /// reconstrói o que falta sem re-subir nada.
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

  /// Devolve os que falharam de vez pra fila, com contador zerado.
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
  // Apagar do celular (agora com conferência real no Drive)
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

    // Conferência real: lista o que existe no Drive e só apaga o que bater
    // por fileId + tamanho (ou nome + pasta + tamanho, pros envios antigos
    // que ainda não guardavam fileId).
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
          porChave[chave] = quantos - 1; // consome, pra não validar 2 locais com 1 do Drive
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

    // Apaga em LOTES de 800 (mais que isso estoura o limite do Android).
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
    _iniciarBackupEngine();
    _load();
    // Rede de segurança: a cada 15s reconcilia com o banco e repõe a janela,
    // mesmo que algum evento ao vivo tenha se perdido.
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _tick());
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
    // Indo pro fundo ou fechando: garante o flush do progresso no disco.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _store.gravarAgora();
    }
  }

  Future<void> _iniciarBackupEngine() async {
    // O store agora vive em arquivos na pasta de dados do app (aguenta 30 mil
    // ids sem reescrever tudo a cada gravação). Init ANTES de qualquer leitura.
    await _store.init(await Nativo.dirDados());

    await BackupService.configurar();
    // Listener PRIMEIRO: o iniciarMotor() reprocessa o que terminou em segundo
    // plano, e sem o listener no ar essas conclusões se perderiam.
    _sub = FileDownloader().updates.listen(_onUpdate);
    await BackupService.iniciarMotor();

    // Reconcilia com o banco da biblioteca: tudo que consta como concluído
    // (até o que subiu com o app fechado) entra nos enviados, e o registro
    // reconciliado sai do banco (mantém o banco pequeno e o boot rápido).
    final concluidos = await BackupService.concluidosNoBanco();
    for (final id in concluidos) {
      await _store.marcarEnviado(id);
      await BackupService.limparRegistro(id);
    }
    await _store.gravarAgora();

    // Limpeza única da fila herdada das builds antigas.
    if (await _store.precisaLimparFila()) {
      await BackupService.limparFilaLegada();
      await _store.marcarFilaLimpa();
    }

    // Restaura o login da última vez (sem pedir nada), pra retomar sozinho.
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
    // Retoma sozinho na janela (a não ser que o usuário tenha pausado).
    _retomarJanela(job);
  }

  // Resposta rápida a um evento ao vivo. A rede de segurança é o tick de 15s
  // guiado pelo banco da biblioteca.
  void _onUpdate(TaskUpdate update) async {
    if (update is! TaskStatusUpdate ||
        update.task.group != BackupService.grupo) {
      return;
    }
    final id = update.task.taskId;
    if (update.status == TaskStatus.complete) {
      // A resposta final do Drive traz o fileId e o tamanho: é a prova que a
      // conferência antes de apagar usa.
      final (fileId, bytes) =
          BackupService.extrairArquivoDaResposta(update.responseBody);
      await _confirmarEnvio(id, fileId, bytes);
      // Se o arquivo local era uma cópia no cache do app, apaga (senão o cache
      // cresce até o tamanho do backup num celular que já está cheio).
      await BackupService.apagarCopiaDeCache(update.task);
      if (mounted) setState(() {});
      _tick();
    } else if (update.status == TaskStatus.failed ||
        update.status == TaskStatus.notFound) {
      await BackupService.apagarCopiaDeCache(update.task);
      final exc = update.exception;
      final quota = exc is TaskHttpException && exc.httpResponseCode == 403;
      if (quota) {
        // 403 na URL da sessão (que dispensa auth) é cota estourada.
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
        // Falhou mesmo depois das retentativas internas: tenta de novo com
        // uma sessão nova, no fim da fila.
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

    // Uma consulta só ao MediaStore traz tamanho e caminho de tudo. Acaba com
    // o "ler arquivo por arquivo" que custava minutos na primeira abertura.
    final infoFut = Nativo.midias();

    // Pagina a listagem: a primeira tela aparece em segundos mesmo com 19 mil
    // arquivos, em vez de esperar um platform-call gigante.
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
      _calculando = faltam > 0;
      _lidos = items.length - faltam;
    });
    if (faltam > 0) _calcularTamanhosFallback();
  }

  /// Fallback raro: mede só o que o MediaStore não devolveu (bytes == 0).
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
    // O fallback pode ter deixado cópias no cache do photo_manager: limpa,
    // desde que nenhum upload esteja usando uma cópia agora.
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

  // ---------------------------------------------------------------------------
  // Velocidade e estimativa
  // ---------------------------------------------------------------------------

  /// Bytes por segundo na média dos últimos 5 minutos. 0 = sem dado ainda.
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

    // Progresso por BYTES quando dá: mais honesto que contagem quando os
    // vídeos grandes sobram pro fim. Cai pra contagem se não tem tamanho.
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
