import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';

/// Um arquivo pra subir: id (asset.id, vira o taskId), nome e a subpasta no Drive.
class ItemBackup {
  final String id;
  final String titulo;
  final String pasta;
  ItemBackup(this.id, this.titulo, this.pasta);

  Map<String, String> toMap() => {'id': id, 'titulo': titulo, 'pasta': pasta};
  static ItemBackup fromMap(Map<String, String> m) =>
      ItemBackup(m['id'] ?? '', m['titulo'] ?? 'sem nome', m['pasta'] ?? 'Outros');
}

/// Upload em segundo plano via background_downloader, em JANELA DESLIZANTE.
///
/// Em vez de despejar milhares de tarefas de uma vez no Android (o que engasga o
/// WorkManager, segura o app criando sessões e estoura o token de 1h), o app
/// mantém poucos uploads ativos por vez e vai enfileirando o próximo conforme
/// um termina. Quem controla a janela é o main; aqui ficam as peças: preparar o
/// contexto (token + pasta) e enfileirar UM arquivo.
class BackupService {
  static const grupo = 'backup';

  // Contexto da sessão atual de upload (renovado quando o token expira).
  static drive.DriveApi? _api;
  static String? _token;
  static String? _mainId;
  static final Map<String, String> _subCache = {};

  /// Configura notificação e permissão. Chamar no início, ANTES do listener e
  /// do iniciarMotor.
  static Future<void> configurar() async {
    // Notificação ESTÁTICA de propósito. Os placeholders {numFinished}/{numTotal}
    // do background_downloader contam só as tarefas do grupo ativas na janela
    // (4 a 6 por vez), não o total real da sessão, então mostravam número errado
    // (ou cru, quando não substituíam). Pior: a notificação "complete" disparava
    // toda vez que a janela esvaziava entre uma leva e outra, gerando a enxurrada
    // de notificações. Texto fixo aqui mata os dois problemas. O número real da
    // sessão ("X de Y") e a barra de % vivem no banner do app, que é a fonte certa.
    FileDownloader().configureNotificationForGroup(
      grupo,
      running: const TaskNotification(
          'Limpa Memória', 'Fazendo backup… pode fechar o app'),
      complete: const TaskNotification('Limpa Memória', 'Backup em dia'),
      error: const TaskNotification(
          'Limpa Memória', 'Backup pausado, reabra o app pra continuar'),
      progressBar: false,
    );
    // Roda os uploads em primeiro plano: remove o teto de 9 minutos por tarefa
    // do Android, que matava os vídeos grandes (e entupia a fila). Exige a
    // notificação 'running' acima e a permissão FOREGROUND_SERVICE_DATA_SYNC +
    // o serviço no AndroidManifest.
    await FileDownloader()
        .configure(globalConfig: (Config.runInForeground, Config.always));
    await FileDownloader().permissions.request(PermissionType.notifications);
  }

  /// Liga o motor: ativa o banco e reprocessa o que terminou em segundo plano.
  /// Não usa rescheduleKilledTasks de propósito (ele reviveria os milhares de
  /// tarefas que as builds antigas despejaram). Quem retoma é a janela do main.
  /// O listener de updates PRECISA já estar registrado antes desta chamada.
  static Future<void> iniciarMotor() async {
    await FileDownloader().trackTasks();
    await FileDownloader().resumeFromBackground();
  }

  /// Limpeza única: cancela tudo que está na fila (herança das builds antigas que
  /// enfileiravam milhares de uma vez). A contagem do que já subiu não se perde,
  /// porque ela vive no nosso próprio armazenamento e no banco da biblioteca.
  static Future<void> limparFilaLegada() async {
    try {
      // reset cancela todas as tarefas em andamento do grupo.
      await FileDownloader().reset(group: grupo);
    } catch (_) {}
  }

  /// Fonte da verdade do que já subiu: tudo que o banco da biblioteca marca como
  /// concluído, inclusive o que terminou com o app fechado. Usado pra reconciliar
  /// a contagem ao abrir e evitar re-subir (duplicata no Drive).
  static Future<Set<String>> concluidosNoBanco() async {
    final records = await FileDownloader().database.allRecords();
    return records
        .where((r) => r.task.group == grupo && r.status == TaskStatus.complete)
        .map((r) => r.taskId)
        .toSet();
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

  /// Prepara o contexto pra enfileirar: token fresco, cliente do Drive e a pasta
  /// principal. Chamar antes de começar a alimentar a janela.
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

  /// Renova o token (e o cliente) quando o anterior expira no meio de um job longo.
  static Future<String?> _renovarToken(GoogleSignIn gsi) async {
    try {
      final conta = await gsi.signInSilently();
      final client = await gsi.authenticatedClient();
      if (client != null) _api = drive.DriveApi(client);
      _token = (await conta?.authentication)?.accessToken;
    } catch (_) {}
    return _token;
  }

  /// Enfileira UM arquivo: garante a subpasta, abre a sessão retomável e manda
  /// pro background_downloader. Devolve (ok, erro). Renova o token se ele expirou.
  static Future<(bool, String?)> enfileirarUm(
      GoogleSignIn gsi, ItemBackup item) async {
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

      final asset = await AssetEntity.fromId(item.id)
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
      final file = await asset?.file
          .timeout(const Duration(seconds: 60), onTimeout: () => null);
      if (file == null) {
        return (false, 'Não consegui abrir "${item.titulo}" a tempo.');
      }

      var (sessao, erroSessao) = await _criarSessao(_token!, item.titulo, subId);
      if (sessao == null) {
        // Pode ser token expirado: renova e tenta de novo uma vez.
        final novo = await _renovarToken(gsi);
        if (novo != null) {
          (sessao, erroSessao) = await _criarSessao(novo, item.titulo, subId);
        }
      }
      if (sessao == null) return (false, erroSessao);

      final (baseDir, directory, filename) =
          await Task.split(filePath: file.path);
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
        // Muitas retentativas com espera crescente: sobrevive a quedas curtas de
        // rede/DNS sem desistir do arquivo.
        retries: 10,
        metaData: item.pasta,
      );
      final ok = await FileDownloader().enqueue(tarefa);
      return ok ? (true, null) : (false, 'O Android recusou enfileirar.');
    } catch (e) {
      return (false, '$e');
    }
  }

  /// Pré-cria/encontra todas as subpastas de uma leva ANTES de enfileirar em
  /// paralelo. Sem isso, dois uploads paralelos da mesma pasta nova criariam a
  /// pasta duas vezes no Drive. Roda em sequência (rápido, é só metadado) e
  /// popula o cache; depois o paralelo só lê do cache.
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

  /// Repete uma chamada de rede em queda momentânea (DNS/socket caindo no meio
  /// de um job de horas, o erro "Failed host lookup" da print). Espera crescente.
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
    final criada =
        await _comRetry(() => api.files.create(nova).timeout(const Duration(seconds: 30)));
    return criada.id!;
  }

  /// Abre uma sessão de upload retomável no Drive. Devolve (urlDaSessao, erro).
  static Future<(String?, String?)> _criarSessao(
      String token, String nome, String folderId) async {
    try {
      final resp = await http
          .post(
            Uri.parse(
                'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id'),
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
        return (null, 'Drive não devolveu a URL da sessão (HTTP ${resp.statusCode}).');
      }
      if (resp.statusCode == 401) return (null, 'token-expirado');
      return (null, 'Drive recusou (HTTP ${resp.statusCode}).');
    } catch (e) {
      return (null, 'Falha de rede ao preparar: $e');
    }
  }
}
