import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

  ItemBackup(this.id, this.titulo, this.pasta, {this.path = '', this.bytes = 0});

  Map<String, String> toMap() => {
        'id': id,
        'titulo': titulo,
        'pasta': pasta,
        if (path.isNotEmpty) 'path': path,
        if (bytes > 0) 'bytes': '$bytes',
      };

  static ItemBackup fromMap(Map<String, String> m) => ItemBackup(
        m['id'] ?? '',
        m['titulo'] ?? 'sem nome',
        m['pasta'] ?? 'Outros',
        path: m['path'] ?? '',
        bytes: int.tryParse(m['bytes'] ?? '') ?? 0,
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
  MetaTarefa(this.pasta, this.cache, this.bytes);

  String codificar() =>
      jsonEncode({'p': pasta, 'c': cache ? 1 : 0, 'b': bytes});

  static MetaTarefa decodificar(String raw) {
    try {
      final m = jsonDecode(raw) as Map;
      return MetaTarefa(
        m['p']?.toString() ?? 'Outros',
        (m['c'] as num?)?.toInt() == 1,
        (m['b'] as num?)?.toInt() ?? 0,
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
class BackupService {
  static const grupo = 'backup';

  /// Erro-marcador de cota cheia no Drive. O main trata como pausa automática.
  static const erroDriveCheio = 'drive-cheio';

  // Contexto da sessão atual de upload (renovado quando o token expira).
  static drive.DriveApi? _api;
  static String? _token;
  static String? _mainId;
  static final Map<String, String> _subCache = {};

  /// Configura notificação e permissão. Chamar no início, ANTES do listener e
  /// do iniciarMotor.
  static Future<void> configurar() async {
    // Notificação ESTÁTICA de propósito. Os placeholders {numFinished}/{numTotal}
    // contam só as tarefas ativas na janela, não o total real da sessão. O
    // número real ("X de Y") e a barra vivem no banner do app.
    FileDownloader().configureNotificationForGroup(
      grupo,
      running: const TaskNotification(
          'Limpa Memória', 'Fazendo backup… deixe o app aberto na tomada'),
      complete: const TaskNotification('Limpa Memória', 'Backup em dia'),
      error: const TaskNotification(
          'Limpa Memória', 'Backup pausado, reabra o app pra continuar'),
      progressBar: false,
    );
    // Roda os uploads em primeiro plano: remove o teto de 9 minutos por tarefa
    // do Android, que matava os vídeos grandes.
    await FileDownloader()
        .configure(globalConfig: (Config.runInForeground, Config.always));
    await FileDownloader().permissions.request(PermissionType.notifications);
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

  /// Fonte da verdade do que já subiu: tudo que o banco da biblioteca marca
  /// como concluído, inclusive o que terminou com o app fechado.
  static Future<Set<String>> concluidosNoBanco() async {
    final records = await FileDownloader().database.allRecords();
    return records
        .where((r) => r.task.group == grupo && r.status == TaskStatus.complete)
        .map((r) => r.taskId)
        .toSet();
  }

  /// Apaga do banco da biblioteca o registro de uma tarefa já reconciliada.
  /// Mantém o banco pequeno em uso longo (sem isso ele cresce sem limite e o
  /// allRecords do boot fica lento). Só chamar DEPOIS de marcar no nosso store.
  static Future<void> limparRegistro(String taskId) async {
    try {
      await FileDownloader().database.deleteRecordWithId(taskId);
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
    final r = await FileDownloader().database.recordForId(id);
    return r?.status;
  }

  /// Quanto cabe no Drive. Devolve null se a conta não tem limite definido.
  static Future<int?> espacoLivre(GoogleSignIn gsi) async {
    final client = await gsi.authenticatedClient();
    if (client == null) return null;
    final api = drive.DriveApi(client);
    final about = await api.about.get($fields: 'storageQuota');
    final q = about.storageQuota;
    final usado = int.tryParse(q?.usage ?? '0') ?? 0;
    final limite = int.tryParse(q?.limit ?? '0') ?? 0;
    return limite == 0 ? null : limite - usado;
  }

  /// Prepara o contexto pra enfileirar: token fresco, cliente do Drive e a
  /// pasta principal. Chamar antes de começar a alimentar a janela.
  static Future<(bool, String?)> prepararContexto(GoogleSignIn gsi) async {
    try {
      final conta = gsi.currentUser;
      final client = await gsi.authenticatedClient();
      if (conta == null || client == null) {
        return (false, 'Você não está conectado ao Google. Entre de novo.');
      }
      _api = drive.DriveApi(client);
      _token = (await conta.authentication).accessToken;
      if (_token == null) {
        return (false, 'Não consegui o token do Google. Saia e entre de novo.');
      }
      _mainId = await _acharOuCriarPasta(_api!, 'Limpa Memória', null);
      _subCache.clear();
      return (true, null);
    } catch (e) {
      return (false, 'Não consegui preparar o Drive: $e');
    }
  }

  /// Renova o token (e o cliente) quando o anterior expira num job longo.
  static Future<String?> _renovarToken(GoogleSignIn gsi) async {
    try {
      final conta = await gsi.signInSilently();
      final client = await gsi.authenticatedClient();
      if (client != null) _api = drive.DriveApi(client);
      _token = (await conta?.authentication)?.accessToken;
    } catch (_) {}
    return _token;
  }

  /// Resolve o arquivo local de um item SEM copiar quando dá: usa o caminho
  /// real do MediaStore se ele existe e é legível. Só cai pro photo_manager
  /// (que pode copiar pro cache) quando o caminho direto falha.
  /// Devolve (caminho, ehCopiaDeCache) ou (null, _) se nada funcionou.
  static Future<(String?, bool)> _resolverArquivo(ItemBackup item) async {
    if (item.path.isNotEmpty) {
      try {
        final f = File(item.path);
        if (await f.exists() && await f.length() > 0) return (item.path, false);
      } catch (_) {}
    }
    final asset = await AssetEntity.fromId(item.id)
        .timeout(const Duration(seconds: 30), onTimeout: () => null);
    if (asset == null) return (null, false);
    File? file;
    try {
      file = await asset.originFile
          .timeout(const Duration(seconds: 120), onTimeout: () => null);
    } catch (_) {}
    file ??= await asset.file
        .timeout(const Duration(seconds: 120), onTimeout: () => null);
    if (file == null) return (null, false);
    // Só é seguro apagar depois se for uma CÓPIA no cache do app. Caminho com
    // /cache/ identifica a cópia; qualquer outra coisa é tratada como original.
    final ehCache = file.path.contains('/cache/');
    return (file.path, ehCache);
  }

  /// Enfileira UM arquivo: garante a subpasta, abre a sessão retomável e manda
  /// pro background_downloader. Devolve (ok, erro). Renova o token se expirou.
  static Future<(bool, String?)> enfileirarUm(
      GoogleSignIn gsi, ItemBackup item,
      {bool soWifi = false}) async {
    try {
      if (_api == null || _mainId == null || _token == null) {
        final (ok, err) = await prepararContexto(gsi);
        if (!ok) return (false, err);
      }

      var subId = _subCache[item.pasta];
      if (subId == null) {
        subId = await _acharOuCriarPasta(_api!, item.pasta, _mainId!);
        _subCache[item.pasta] = subId;
      }

      final (caminho, ehCache) = await _resolverArquivo(item);
      if (caminho == null) {
        return (false, 'Não consegui abrir "${item.titulo}" a tempo.');
      }

      var (sessao, erroSessao) = await _criarSessao(_token!, item.titulo, subId);
      if (sessao == null && erroSessao == 'token-expirado') {
        final novo = await _renovarToken(gsi);
        if (novo != null) {
          (sessao, erroSessao) = await _criarSessao(novo, item.titulo, subId);
        }
      }
      if (sessao == null) return (false, erroSessao);

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
        updates: Updates.statusAndProgress,
        // Muitas retentativas com espera crescente: sobrevive a quedas curtas
        // de rede/DNS sem desistir do arquivo.
        retries: 10,
        requiresWiFi: soWifi,
        metaData: MetaTarefa(item.pasta, ehCache, item.bytes).codificar(),
      );
      final ok = await FileDownloader().enqueue(tarefa);
      return ok ? (true, null) : (false, 'O Android recusou enfileirar.');
    } catch (e) {
      return (false, '$e');
    }
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

  /// Pré-cria/encontra todas as subpastas de uma leva ANTES de enfileirar em
  /// paralelo (senão dois uploads da mesma pasta nova criariam a pasta 2x).
  static Future<void> garantirSubpastas(
      GoogleSignIn gsi, Iterable<String> nomes) async {
    if (_api == null || _mainId == null) {
      final (ok, _) = await prepararContexto(gsi);
      if (!ok) return;
    }
    for (final nome in nomes.toSet()) {
      if (_subCache.containsKey(nome)) continue;
      try {
        _subCache[nome] = await _acharOuCriarPasta(_api!, nome, _mainId!);
      } catch (_) {
        // deixa pro enfileirarUm tentar de novo por arquivo
      }
    }
  }

  /// Lista TUDO que está na pasta Limpa Memória do Drive (subpastas e seus
  /// arquivos), paginado. Duas serventias:
  /// - conferir de verdade antes de apagar do celular (fileId + tamanho);
  /// - reconhecer um backup antigo depois de reinstalar o app (o escopo
  ///   drive.file enxerga o que o próprio app criou, mesmo após reinstalar).
  /// Custo: 1 chamada por subpasta por página de 1000. Pra 19 mil arquivos,
  /// coisa de ~25 chamadas de metadado.
  static Future<List<ArquivoDrive>?> listarNoDrive(GoogleSignIn gsi) async {
    try {
      if (_api == null || _mainId == null) {
        final (ok, _) = await prepararContexto(gsi);
        if (!ok) return null;
      }
      final api = _api!;
      final resultado = <ArquivoDrive>[];
      // Subpastas da pasta principal.
      final subs = <String, String>{}; // id -> nome
      String? pageToken;
      do {
        final res = await _comRetry(() => api.files
            .list(
              q: "mimeType='application/vnd.google-apps.folder' and '${_mainId!}' in parents and trashed=false",
              $fields: 'nextPageToken, files(id,name)',
              pageSize: 1000,
              pageToken: pageToken,
            )
            .timeout(const Duration(seconds: 30)));
        for (final f in res.files ?? const <drive.File>[]) {
          if (f.id != null) subs[f.id!] = f.name ?? '';
        }
        pageToken = res.nextPageToken;
      } while (pageToken != null);

      // Arquivos de cada subpasta (e da raiz, por via das dúvidas).
      final pais = <String, String>{_mainId!: '', ...subs};
      for (final entry in pais.entries) {
        String? pt;
        do {
          final res = await _comRetry(() => api.files
              .list(
                q: "'${entry.key}' in parents and mimeType!='application/vnd.google-apps.folder' and trashed=false",
                $fields: 'nextPageToken, files(id,name,size)',
                pageSize: 1000,
                pageToken: pt,
              )
              .timeout(const Duration(seconds: 60)));
          for (final f in res.files ?? const <drive.File>[]) {
            if (f.id == null) continue;
            resultado.add(ArquivoDrive(
              f.id!,
              f.name ?? '',
              int.tryParse(f.size ?? '') ?? 0,
              entry.value,
            ));
          }
          pt = res.nextPageToken;
        } while (pt != null);
      }
      return resultado;
    } catch (_) {
      return null; // rede caiu no meio: quem chamou decide o que fazer
    }
  }

  /// Repete uma chamada de rede em queda momentânea (DNS/socket caindo no meio
  /// de um job de horas). Espera crescente.
  static Future<T> _comRetry<T>(Future<T> Function() fn,
      {int tentativas = 4}) async {
    var espera = const Duration(seconds: 2);
    for (var i = 0;; i++) {
      try {
        return await fn();
      } catch (e) {
        final msg = '$e';
        final transitorio = e is SocketException ||
            e is http.ClientException ||
            e is TimeoutException ||
            msg.contains('Failed host lookup') ||
            msg.contains('SocketException') ||
            msg.contains('Connection reset') ||
            msg.contains('Connection closed');
        if (!transitorio || i >= tentativas - 1) rethrow;
        await Future.delayed(espera);
        espera *= 2;
      }
    }
  }

  static Future<String> _acharOuCriarPasta(
      drive.DriveApi api, String nome, String? parentId) async {
    final nomeEsc = nome.replaceAll("'", r"\'");
    var q =
        "mimeType='application/vnd.google-apps.folder' and name='$nomeEsc' and trashed=false";
    if (parentId != null) q += " and '$parentId' in parents";
    final res = await _comRetry(() => api.files
        .list(q: q, $fields: 'files(id,name)')
        .timeout(const Duration(seconds: 30)));
    if (res.files != null && res.files!.isNotEmpty) {
      return res.files!.first.id!;
    }
    final nova = drive.File()
      ..name = nome
      ..mimeType = 'application/vnd.google-apps.folder';
    if (parentId != null) nova.parents = [parentId];
    final criada = await _comRetry(
        () => api.files.create(nova).timeout(const Duration(seconds: 30)));
    return criada.id!;
  }

  /// Abre uma sessão de upload retomável no Drive. Devolve (urlDaSessao, erro).
  /// O fields=id,name,size faz a resposta FINAL do upload devolver o fileId e
  /// o tamanho, que a gente guarda pra conferir antes de apagar do celular.
  static Future<(String?, String?)> _criarSessao(
      String token, String nome, String folderId) async {
    try {
      final resp = await http
          .post(
            Uri.parse(
                'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,name,size'),
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
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final loc = resp.headers['location'];
        if (loc != null && loc.isNotEmpty) return (loc, null);
        return (
          null,
          'Drive não devolveu a URL da sessão (HTTP ${resp.statusCode}).'
        );
      }
      if (resp.statusCode == 401) return (null, 'token-expirado');
      if (resp.statusCode == 403 &&
          (resp.body.contains('storageQuotaExceeded') ||
              resp.body.contains('quotaExceeded'))) {
        return (null, erroDriveCheio);
      }
      return (null, 'Drive recusou (HTTP ${resp.statusCode}).');
    } catch (e) {
      return (null, 'Falha de rede ao preparar: $e');
    }
  }

  /// Extrai o fileId (e tamanho) da resposta final de um upload concluído.
  /// Devolve (fileId, bytes) ou (null, null) se a resposta não veio.
  static (String?, int?) extrairArquivoDaResposta(String? responseBody) {
    if (responseBody == null || responseBody.isEmpty) return (null, null);
    try {
      final m = jsonDecode(responseBody) as Map;
      final id = m['id']?.toString();
      final size = int.tryParse(m['size']?.toString() ?? '');
      return (id, size);
    } catch (_) {
      return (null, null);
    }
  }
}
