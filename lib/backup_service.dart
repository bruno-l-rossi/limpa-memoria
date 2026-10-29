import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:background_downloader/background_downloader.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';

/// Um arquivo pra subir: id (asset.id, vira o taskId), nome, subpasta no Drive,
/// e (rodada 8) o caminho real no disco e o tamanho, vindos do MediaStore.
/// Com o caminho real o upload lê o arquivo direto, sem copiar pro cache.
class ItemBackup {
  final String id;
  final String titulo;
  final String pasta;
  final String path; // vazio = sem caminho direto, usa o fallback
  final int bytes; // 0 = desconhecido
  // Duplicata exata: id do item PRINCIPAL que sobe no lugar deste (mesmo nome
  // + mesmo tamanho). Item com dup não é enfileirado; quando o principal
  // confirma, este é marcado como coberto pelo mesmo arquivo do Drive.
  final String dup;

  ItemBackup(this.id, this.titulo, this.pasta,
      {this.path = '', this.bytes = 0, this.dup = ''});

  ItemBackup comDup(String novoDup) =>
      ItemBackup(id, titulo, pasta, path: path, bytes: bytes, dup: novoDup);

  Map<String, String> toMap() => {
        'id': id,
        'titulo': titulo,
        'pasta': pasta,
        if (path.isNotEmpty) 'path': path,
        if (bytes > 0) 'bytes': '$bytes',
        if (dup.isNotEmpty) 'dup': dup,
      };

  static ItemBackup fromMap(Map<String, String> m) => ItemBackup(
        m['id'] ?? '',
        m['titulo'] ?? 'sem nome',
        m['pasta'] ?? 'Outros',
        path: m['path'] ?? '',
        bytes: int.tryParse(m['bytes'] ?? '') ?? 0,
        dup: m['dup'] ?? '',
      );
}

/// Um arquivo como está no Drive (da listagem da pasta Limpa Memória).
/// Usado pra conferir antes de apagar do celular e pra reconhecer um backup
/// antigo depois de reinstalar o app.
class ArquivoDrive {
  final String fileId;
  final String nome;
  final int bytes;
  final String pasta;
  ArquivoDrive(this.fileId, this.nome, this.bytes, this.pasta);
}

/// Metadados que viajam dentro da tarefa do background_downloader.
/// cache=true significa "o arquivo local é uma cópia no cache do app e pode
/// ser apagada quando o upload terminar" (nunca apagar o original!).
class MetaTarefa {
  final String pasta;
  final bool cache;
  final int bytes;
  final String titulo; // nome no Drive (o filename local pode ser de cache)
  MetaTarefa(this.pasta, this.cache, this.bytes, {this.titulo = ''});

  String codificar() => jsonEncode({
        'p': pasta,
        'c': cache ? 1 : 0,
        'b': bytes,
        if (titulo.isNotEmpty) 't': titulo,
      });

  static MetaTarefa decodificar(String raw) {
    try {
      final m = jsonDecode(raw) as Map;
      return MetaTarefa(
        m['p']?.toString() ?? 'Outros',
        (m['c'] as num?)?.toInt() == 1,
        (m['b'] as num?)?.toInt() ?? 0,
        titulo: m['t']?.toString() ?? '',
      );
    } catch (_) {
      // metaData das builds antigas era o nome cru da pasta
      return MetaTarefa(raw.isEmpty ? 'Outros' : raw, false, 0);
    }
  }
}

/// Upload em segundo plano via background_downloader, em JANELA DESLIZANTE.
///
/// O main controla a janela (quantos sobem por vez); aqui ficam as peças:
/// preparar o contexto (token + pasta), enfileirar UM arquivo, e as leituras
/// e limpezas do banco da biblioteca.
///
/// Rodada 10:
/// - o contexto (token + cliente do Drive) tem validade. O token do Google
///   dura 1 hora; antes, depois de 1h de job, a listagem do Drive falhava com
///   401 e o "Apagar do celular" dizia "sem rede" pra sempre. Agora renova
///   sozinho (e também ao receber 401 de qualquer chamada);
/// - erros são classificados: REDE (queda, DNS, 429, 5xx, limite de taxa do
///   Drive) é transitório e o main espera sem gastar tentativa do arquivo;
///   SUMIU (arquivo não existe mais no celular) sai do backup; o resto conta
///   tentativa;
/// - a sessão retomável é criada com retentativa e espera crescente;
/// - notificação do serviço agrupada numa só (antes, uma por tarefa);
/// - só eventos de STATUS (sem progresso): o progresso por arquivo nunca foi
///   usado e gerava escrita em disco no banco da biblioteca a cada update.
class BackupService {
  static const grupo = 'backup';

  /// Erro-marcador de cota cheia no Drive. O main trata como pausa automática.
  static const erroDriveCheio = 'drive-cheio';

  /// Prefixo de erro transitório (rede, limite de taxa). Não gasta tentativa.
  static const prefixoRede = 'rede: ';

  /// Erro-marcador: o arquivo não existe mais no celular.
  static const erroSumiu = 'sumiu';

  static bool ehRede(String? erro) =>
      erro != null && erro.startsWith(prefixoRede);

  // Contexto da sessão atual de upload (renovado quando o token expira).
  static drive.DriveApi? _api;
  static String? _token;
  static String? _mainId;
  static List<String> _mainIds = const []; // todas as pastas principais
  static DateTime? _contextoEm;
  static Future<(bool, String?)>? _preparando;
  static final Map<String, String> _subCache = {};
  static final Map<String, Future<String>> _subCriando = {};

  // Token do Google vale 60 min. Renova antes, com folga.
  static const _validadeContexto = Duration(minutes: 40);

  /// Configura notificação e permissão. Chamar no início, ANTES do listener e
  /// do iniciarMotor.
  static Future<void> configurar() async {
    // Uma notificação SÓ pro grupo inteiro (groupNotificationId). Texto fixo:
    // o número real ("X de Y") vem na notificação de progresso do app.
    FileDownloader().configureNotificationForGroup(
      grupo,
      running: const TaskNotification(
          'Limpa Memória', 'Fazendo backup… deixe o app aberto na tomada'),
      complete: const TaskNotification(
          'Limpa Memória', 'Fila do Android concluída. Abra o app pra continuar'),
      error: const TaskNotification(
          'Limpa Memória', 'Backup pausado, reabra o app pra continuar'),
      progressBar: false,
      groupNotificationId: grupo,
    );
    // Roda os uploads em primeiro plano: remove o teto de 9 minutos por tarefa
    // do Android, que matava os vídeos grandes.
    try {
      await FileDownloader()
          .configure(globalConfig: (Config.runInForeground, Config.always));
    } catch (_) {}
    try {
      await FileDownloader().permissions.request(PermissionType.notifications);
    } catch (_) {}
  }

  /// Liga o motor: ativa o banco e reprocessa o que terminou em segundo plano.
  /// O listener de updates PRECISA já estar registrado antes desta chamada.
  static Future<void> iniciarMotor() async {
    await FileDownloader().trackTasks();
    await FileDownloader().resumeFromBackground();
  }

  /// Limpeza única: cancela tudo que está na fila (herança das builds antigas
  /// que enfileiravam milhares de uma vez).
  static Future<void> limparFilaLegada() async {
    try {
      await FileDownloader().reset(group: grupo);
    } catch (_) {}
  }

  /// Cancela tudo que está na fila do Android (botão Parar). As sessões no
  /// Drive ficam abandonadas e expiram sozinhas; o Retomar cria novas.
  static Future<void> cancelarTodos() async {
    try {
      final ids = await idsAtivos();
      if (ids.isNotEmpty) {
        await FileDownloader().cancelTasksWithIds(ids);
      }
    } catch (_) {}
  }

  /// Fonte da verdade do que já subiu: tudo que o banco da biblioteca marca
  /// como concluído, inclusive o que terminou com o app fechado.
  static Future<Set<String>> concluidosNoBanco() async {
    try {
      final records = await FileDownloader().database.allRecords(group: grupo);
      return records
          .where((r) => r.status == TaskStatus.complete)
          .map((r) => r.taskId)
          .toSet();
    } catch (_) {
      return {};
    }
  }

  /// Apaga do banco da biblioteca registros já reconciliados no nosso store.
  /// Mantém o banco pequeno em uso longo. Só chamar DEPOIS de marcar no store.
  static Future<void> limparRegistros(Iterable<String> taskIds) async {
    final ids = taskIds.toList();
    if (ids.isEmpty) return;
    try {
      await FileDownloader().database.deleteRecordsWithIds(ids);
    } catch (_) {}
  }

  /// Ids que já estão na fila de upload (rodando, esperando ou pra retentar).
  static Future<Set<String>> idsAtivos() async {
    final ids = await FileDownloader()
        .allTaskIds(group: grupo, includeTasksWaitingToRetry: true);
    return ids.toSet();
  }

  /// Status de UM arquivo no banco (leitura barata por id).
  static Future<TaskStatus?> statusDe(String id) async {
    try {
      final r = await FileDownloader().database.recordForId(id);
      return r?.status;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Contexto (token + cliente + pasta principal)
  // ---------------------------------------------------------------------------

  static bool get _contextoValido {
    final em = _contextoEm;
    return _api != null &&
        _token != null &&
        _mainId != null &&
        em != null &&
        DateTime.now().difference(em) < _validadeContexto;
  }

  /// Garante um contexto fresco. Barato quando ainda vale.
  static Future<(bool, String?)> garantirContexto(GoogleSignIn gsi) async {
    if (_contextoValido) return (true, null);
    return prepararContexto(gsi);
  }

  /// Prepara o contexto pra enfileirar: token fresco, cliente do Drive e a
  /// pasta principal. Chamadas simultâneas compartilham a mesma preparação.
  static Future<(bool, String?)> prepararContexto(GoogleSignIn gsi,
      {bool forcarToken = false}) {
    final emCurso = _preparando;
    if (emCurso != null) return emCurso;
    final f = _preparar(gsi, forcarToken).whenComplete(() => _preparando = null);
    _preparando = f;
    return f;
  }

  static Future<(bool, String?)> _preparar(
      GoogleSignIn gsi, bool forcarToken) async {
    try {
      var conta = gsi.currentUser;
      conta ??= await gsi
          .signInSilently()
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
      if (conta == null) {
        return (false, 'Você não está conectado ao Google. Entre de novo.');
      }
      if (forcarToken) {
        try {
          await conta.clearAuthCache();
        } catch (_) {}
      }
      final auth =
          await conta.authentication.timeout(const Duration(seconds: 30));
      final token = auth.accessToken;
      if (token == null) {
        return (false, 'Não consegui o token do Google. Saia e entre de novo.');
      }
      final client = await gsi.authenticatedClient();
      if (client == null) {
        return (false, 'Você não está conectado ao Google. Entre de novo.');
      }
      _api = drive.DriveApi(client);
      _token = token;
      if (_mainId == null) {
        final mains = await _acharPastas(_api!, 'Limpa Memória', null);
        if (mains.isEmpty) {
          _mainId = await _criarPasta(_api!, 'Limpa Memória', null);
          _mainIds = [_mainId!];
        } else {
          _mainId = mains.first;
          _mainIds = mains;
        }
        _subCache.clear();
      }
      _contextoEm = DateTime.now();
      return (true, null);
    } catch (e) {
      if (_ehTransitorio(e)) {
        return (false, '${prefixoRede}sem conexão com o Google ($e)');
      }
      return (false, 'Não consegui preparar o Drive: $e');
    }
  }

  /// Renova o token (e o cliente) quando o anterior expira.
  static Future<String?> _renovarToken(GoogleSignIn gsi) async {
    _contextoEm = null;
    final (ok, _) = await prepararContexto(gsi, forcarToken: true);
    return ok ? _token : null;
  }

  /// Quanto cabe no Drive. Devolve null se a conta não tem limite definido ou
  /// se não deu pra ler (sem rede).
  static Future<int?> espacoLivre(GoogleSignIn gsi) async {
    try {
      final about =
          await _naApi(gsi, (api) => api.about.get($fields: 'storageQuota'));
      final q = about.storageQuota;
      final usado = int.tryParse(q?.usage ?? '0') ?? 0;
      final limite = int.tryParse(q?.limit ?? '0') ?? 0;
      return limite == 0 ? null : limite - usado;
    } catch (_) {
      return null;
    }
  }

  /// Quota do Drive (usado, limite) pro diálogo de espaço. Lança em erro.
  static Future<(int, int)> quota(GoogleSignIn gsi) async {
    final about =
        await _naApi(gsi, (api) => api.about.get($fields: 'storageQuota'));
    final q = about.storageQuota;
    return (
      int.tryParse(q?.usage ?? '0') ?? 0,
      int.tryParse(q?.limit ?? '0') ?? 0,
    );
  }

  // ---------------------------------------------------------------------------
  // Enfileirar
  // ---------------------------------------------------------------------------

  /// Resolve o arquivo local de um item SEM copiar quando dá: usa o caminho
  /// real do MediaStore se ele existe e é legível. Só cai pro photo_manager
  /// (que pode copiar pro cache) quando o caminho direto falha.
  /// Devolve (caminho, ehCopiaDeCache, sumiu).
  static Future<(String?, bool, bool)> _resolverArquivo(ItemBackup item) async {
    if (item.path.isNotEmpty) {
      try {
        final f = File(item.path);
        if (await f.exists() && await f.length() > 0) {
          return (item.path, false, false);
        }
      } catch (_) {}
    }
    AssetEntity? asset;
    try {
      asset = await AssetEntity.fromId(item.id)
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
    } catch (_) {}
    if (asset == null) {
      // Não está mais na galeria (apagado por fora do app).
      return (null, false, true);
    }
    File? file;
    try {
      file = await asset.originFile
          .timeout(const Duration(seconds: 120), onTimeout: () => null);
    } catch (_) {}
    if (file == null) {
      try {
        file = await asset.file
            .timeout(const Duration(seconds: 120), onTimeout: () => null);
      } catch (_) {}
    }
    if (file == null) return (null, false, false);
    // Só é seguro apagar depois se for uma CÓPIA no cache do app. Caminho com
    // /cache/ identifica a cópia; qualquer outra coisa é tratada como original.
    final ehCache = file.path.contains('/cache/');
    return (file.path, ehCache, false);
  }

  /// Enfileira UM arquivo: garante a subpasta, abre a sessão retomável e manda
  /// pro background_downloader. Devolve (ok, erro). Renova o token se expirou.
  static Future<(bool, String?)> enfileirarUm(
      GoogleSignIn gsi, ItemBackup item,
      {bool soWifi = false}) async {
    try {
      final (ok, err) = await garantirContexto(gsi);
      if (!ok) return (false, err);

      final (caminho, ehCache, sumiu) = await _resolverArquivo(item);
      if (sumiu) return (false, erroSumiu);
      if (caminho == null) {
        return (false, 'Não consegui abrir "${item.titulo}" a tempo.');
      }

      final subId = await _subpasta(gsi, item.pasta);

      var (sessao, erroSessao) = await _criarSessao(_token!, item.titulo, subId);
      if (sessao == null && erroSessao == 'token-expirado') {
        final novo = await _renovarToken(gsi);
        if (novo != null) {
          (sessao, erroSessao) = await _criarSessao(novo, item.titulo, subId);
        }
        if (sessao == null && erroSessao == 'token-expirado') {
          erroSessao = '${prefixoRede}login do Google expirou, renovando';
        }
      }
      if (sessao == null) {
        if (ehCache) _apagarSeCache(caminho);
        return (false, erroSessao);
      }

      final (baseDir, directory, filename) =
          await Task.split(filePath: caminho);
      final tarefa = UploadTask(
        taskId: item.id,
        url: sessao,
        baseDirectory: baseDir,
        directory: directory,
        filename: filename,
        httpRequestMethod: 'PUT',
        post: 'binary',
        headers: const {'Content-Disposition': ''},
        group: grupo,
        updates: Updates.status,
        // Muitas retentativas com espera crescente: sobrevive a quedas curtas
        // de rede/DNS sem desistir do arquivo.
        retries: 10,
        requiresWiFi: soWifi,
        metaData: MetaTarefa(item.pasta, ehCache, item.bytes,
                titulo: item.titulo)
            .codificar(),
      );
      final ok2 = await FileDownloader().enqueue(tarefa);
      if (!ok2 && ehCache) _apagarSeCache(caminho);
      return ok2
          ? (true, null)
          : (false, '${prefixoRede}o Android recusou enfileirar agora');
    } catch (e) {
      if (_ehTransitorio(e)) return (false, '$prefixoRede$e');
      return (false, '$e');
    }
  }

  static void _apagarSeCache(String caminho) {
    try {
      if (!caminho.contains('/cache/')) return;
      final f = File(caminho);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Apaga a cópia de cache de uma tarefa que terminou (sucesso ou falha
  /// definitiva). NUNCA toca no original: só age se o metaData diz cache=true
  /// e o caminho confirma que está no cache do app.
  static Future<void> apagarCopiaDeCache(Task task) async {
    try {
      final meta = MetaTarefa.decodificar(task.metaData);
      if (!meta.cache) return;
      final caminho = await task.filePath();
      if (!caminho.contains('/cache/')) return;
      final f = File(caminho);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Id da subpasta (cria se não existe). Chamadas simultâneas pra mesma
  /// pasta nova esperam a mesma criação: nunca cria a pasta 2x.
  static Future<String> _subpasta(GoogleSignIn gsi, String nome) async {
    final pronto = _subCache[nome];
    if (pronto != null) return pronto;
    final emCurso = _subCriando[nome];
    if (emCurso != null) return emCurso;
    final f = () async {
      if (_mainId == null) await prepararContexto(gsi);
      final main = _mainId;
      if (main == null) {
        throw const SocketException('pasta principal indisponível');
      }
      final achadas = await _naApiComGsi(
          gsi, (api) => _acharPastas(api, nome, main));
      final id = achadas.isNotEmpty
          ? achadas.first
          : await _naApiComGsi(gsi, (api) => _criarPasta(api, nome, main));
      _subCache[nome] = id;
      return id;
    }();
    _subCriando[nome] = f;
    try {
      return await f;
    } finally {
      _subCriando.remove(nome);
    }
  }

  /// Pré-cria/encontra todas as subpastas de uma leva ANTES de enfileirar em
  /// paralelo.
  static Future<void> garantirSubpastas(
      GoogleSignIn gsi, Iterable<String> nomes) async {
    final (ok, _) = await garantirContexto(gsi);
    if (!ok) return;
    for (final nome in nomes.toSet()) {
      if (_subCache.containsKey(nome)) continue;
      try {
        await _subpasta(gsi, nome);
      } catch (_) {
        // deixa pro enfileirarUm tentar de novo por arquivo
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Listagem e limpeza no Drive
  // ---------------------------------------------------------------------------

  // Cache da listagem do Drive: apagar em 2 levas seguidas não lista 2 vezes.
  static List<ArquivoDrive>? _cacheListagem;
  static DateTime? _cacheListagemEm;
  static const _validadeListagem = Duration(minutes: 10);

  /// Invalida o cache da listagem (chamar quando algo novo sobe).
  static void invalidarListagem() {
    _cacheListagem = null;
    _cacheListagemEm = null;
  }

  /// Lista TUDO que está na(s) pasta(s) Limpa Memória do Drive (subpastas e
  /// seus arquivos), paginado. Duas serventias:
  /// - conferir de verdade antes de apagar do celular (fileId + tamanho);
  /// - reconhecer um backup antigo depois de reinstalar o app.
  /// Custo: 1 chamada por subpasta por página de 1000. Resultado vale 10 min.
  /// Devolve null se não conseguiu listar tudo (rede caiu no meio): quem
  /// chama nunca deve decidir apagar com uma listagem pela metade.
  static Future<List<ArquivoDrive>?> listarNoDrive(GoogleSignIn gsi) async {
    final em = _cacheListagemEm;
    if (_cacheListagem != null &&
        em != null &&
        DateTime.now().difference(em) < _validadeListagem) {
      return _cacheListagem;
    }
    try {
      final (ok, _) = await garantirContexto(gsi);
      if (!ok) return null;
      final resultado = <ArquivoDrive>[];
      // Subpastas de cada pasta principal (pode haver mais de uma "Limpa
      // Memória" criada por builds antigas; todas valem).
      final pais = <String, String>{}; // id -> nome da subpasta
      for (final main in _mainIds) {
        pais[main] = '';
        String? pageToken;
        do {
          final pt = pageToken;
          final res = await _naApi(
              gsi,
              (api) => api.files.list(
                    q: "mimeType='application/vnd.google-apps.folder' and '$main' in parents and trashed=false",
                    $fields: 'nextPageToken, files(id,name)',
                    pageSize: 1000,
                    pageToken: pt,
                  ));
          for (final f in res.files ?? const <drive.File>[]) {
            if (f.id != null) pais[f.id!] = f.name ?? '';
          }
          pageToken = res.nextPageToken;
        } while (pageToken != null);
      }

      // Arquivos de cada subpasta (e da raiz, por via das dúvidas).
      for (final entry in pais.entries) {
        String? pageToken;
        do {
          final pt = pageToken;
          final res = await _naApi(
              gsi,
              (api) => api.files.list(
                    q: "'${entry.key}' in parents and mimeType!='application/vnd.google-apps.folder' and trashed=false",
                    $fields: 'nextPageToken, files(id,name,size)',
                    pageSize: 1000,
                    pageToken: pt,
                  ),
              timeout: const Duration(seconds: 60));
          for (final f in res.files ?? const <drive.File>[]) {
            if (f.id == null) continue;
            resultado.add(ArquivoDrive(
              f.id!,
              f.name ?? '',
              int.tryParse(f.size ?? '') ?? 0,
              entry.value,
            ));
          }
          pageToken = res.nextPageToken;
        } while (pageToken != null);
      }
      _cacheListagem = resultado;
      _cacheListagemEm = DateTime.now();
      return resultado;
    } catch (_) {
      return null; // rede caiu no meio: quem chamou decide o que fazer
    }
  }

  /// Apaga um arquivo no Drive (usado quando o MD5 divergiu: tira o corrompido
  /// de lá antes de re-subir, senão o refazer viraria duplicata).
  static Future<void> apagarNoDrive(GoogleSignIn gsi, String fileId) async {
    try {
      await _naApi(gsi, (api) => api.files.delete(fileId));
      invalidarListagem();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Rede: retentativa, renovação de token e classificação de erro
  // ---------------------------------------------------------------------------

  static bool _ehTransitorio(Object e) {
    if (e is SocketException ||
        e is http.ClientException ||
        e is TimeoutException ||
        e is HandshakeException) {
      return true;
    }
    if (e is drive.DetailedApiRequestError) {
      final s = e.status ?? 0;
      if (s == 429 || s >= 500) return true;
      if (s == 403 &&
          _ehLimiteDeTaxa(
              '${e.message} ${e.errors.map((d) => d.reason).join(' ')} ${e.jsonResponse}')) {
        return true;
      }
      return false;
    }
    final msg = '$e';
    return msg.contains('Failed host lookup') ||
        msg.contains('SocketException') ||
        msg.contains('Connection reset') ||
        msg.contains('Connection closed') ||
        msg.contains('Connection refused') ||
        msg.contains('Network is unreachable') ||
        msg.contains('timed out');
  }

  static bool _ehLimiteDeTaxa(String corpo) =>
      corpo.contains('rateLimitExceeded') ||
      corpo.contains('userRateLimitExceeded') ||
      corpo.contains('Rate Limit');

  static bool _eh401(Object e) =>
      e is drive.DetailedApiRequestError && e.status == 401 ||
      e is drive.ApiRequestError && '$e'.contains('401');

  /// Roda uma chamada na API do Drive com contexto fresco, renovação de token
  /// em 401 e retentativa com espera crescente em erro transitório.
  static Future<T> _naApi<T>(
      GoogleSignIn gsi, Future<T> Function(drive.DriveApi api) fn,
      {Duration timeout = const Duration(seconds: 30),
      int tentativas = 5}) async {
    final (ok, err) = await garantirContexto(gsi);
    if (!ok) throw SocketException(err ?? 'sem contexto do Drive');
    var espera = const Duration(seconds: 2);
    var renovou = false;
    for (var i = 0;; i++) {
      try {
        return await fn(_api!).timeout(timeout);
      } catch (e) {
        if (_eh401(e) && !renovou) {
          renovou = true;
          await _renovarToken(gsi);
          continue;
        }
        if (!_ehTransitorio(e) || i >= tentativas - 1) rethrow;
        await Future.delayed(espera + _jitter());
        espera *= 2;
      }
    }
  }

  /// Igual ao _naApi, mas pra funções que já recebem a api pronta e podem
  /// lançar (usado na criação de subpasta).
  static Future<T> _naApiComGsi<T>(
          GoogleSignIn gsi, Future<T> Function(drive.DriveApi api) fn) =>
      _naApi(gsi, fn);

  static final _rnd = Random();
  static Duration _jitter() => Duration(milliseconds: _rnd.nextInt(1000));

  static String _esc(String nome) =>
      nome.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  /// Todas as pastas com esse nome (mais antiga primeiro).
  static Future<List<String>> _acharPastas(
      drive.DriveApi api, String nome, String? parentId) async {
    var q =
        "mimeType='application/vnd.google-apps.folder' and name='${_esc(nome)}' and trashed=false";
    if (parentId != null) q += " and '$parentId' in parents";
    final res = await api.files
        .list(q: q, $fields: 'files(id,name)', orderBy: 'createdTime')
        .timeout(const Duration(seconds: 30));
    return [
      for (final f in res.files ?? const <drive.File>[])
        if (f.id != null) f.id!
    ];
  }

  static Future<String> _criarPasta(
      drive.DriveApi api, String nome, String? parentId) async {
    final nova = drive.File()
      ..name = nome
      ..mimeType = 'application/vnd.google-apps.folder';
    if (parentId != null) nova.parents = [parentId];
    final criada =
        await api.files.create(nova).timeout(const Duration(seconds: 30));
    return criada.id!;
  }

  /// Abre uma sessão de upload retomável no Drive. Devolve (urlDaSessao, erro).
  /// O fields=id,name,size,md5Checksum faz a resposta FINAL do upload devolver
  /// o fileId, o tamanho e o MD5 que o Drive calculou, que a gente usa pra
  /// conferir a integridade e pra liberar o apagar do celular.
  ///
  /// Repete sozinha em queda de rede, 429, 5xx e limite de taxa do Drive
  /// (o Drive limita quantos arquivos por segundo cada conta cria; com 30 mil
  /// fotos pequenas isso aparece).
  static Future<(String?, String?)> _criarSessao(
      String token, String nome, String folderId) async {
    var espera = const Duration(seconds: 2);
    String? ultimo;
    for (var i = 0; i < 5; i++) {
      if (i > 0) {
        await Future.delayed(espera + _jitter());
        espera *= 2;
      }
      try {
        final resp = await http
            .post(
              Uri.parse(
                  'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,name,size,md5Checksum'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json; charset=UTF-8',
              },
              body: jsonEncode({
                'name': nome,
                'parents': [folderId],
              }),
            )
            .timeout(const Duration(seconds: 30));
        final s = resp.statusCode;
        if (s >= 200 && s < 300) {
          final loc = resp.headers['location'];
          if (loc != null && loc.isNotEmpty) return (loc, null);
          ultimo = '${prefixoRede}Drive não devolveu a URL da sessão';
          continue;
        }
        if (s == 401) return (null, 'token-expirado');
        if (s == 403 &&
            (resp.body.contains('storageQuotaExceeded') ||
                resp.body.contains('"quotaExceeded"'))) {
          return (null, erroDriveCheio);
        }
        if (s == 429 || s >= 500 || (s == 403 && _ehLimiteDeTaxa(resp.body))) {
          ultimo = '${prefixoRede}Drive pediu pra esperar (HTTP $s)';
          continue;
        }
        if (s == 404) {
          // Pasta sumiu no Drive (apagada pelo usuário): esquece o cache.
          _subCache.removeWhere((_, v) => v == folderId);
          if (folderId == _mainId) _mainId = null;
        }
        return (null, 'Drive recusou (HTTP $s).');
      } catch (e) {
        ultimo = '${prefixoRede}falha de rede ao preparar: $e';
      }
    }
    return (null, ultimo ?? '${prefixoRede}falha de rede ao preparar');
  }

  /// Extrai fileId, tamanho e MD5 da resposta final de um upload concluído.
  /// Devolve (null, null, null) se a resposta não veio.
  static (String?, int?, String?) extrairArquivoDaResposta(
      String? responseBody) {
    if (responseBody == null || responseBody.isEmpty) {
      return (null, null, null);
    }
    try {
      final m = jsonDecode(responseBody) as Map;
      final id = m['id']?.toString();
      final size = int.tryParse(m['size']?.toString() ?? '');
      final md5 = m['md5Checksum']?.toString();
      return (id, size, md5);
    } catch (_) {
      return (null, null, null);
    }
  }
}
