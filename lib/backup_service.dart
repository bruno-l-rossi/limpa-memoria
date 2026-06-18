import 'dart:convert';
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

/// Cuida do upload em segundo plano via background_downloader.
///
/// A ideia: cada arquivo vira uma "sessão retomável" no Google Drive (um POST
/// rápido em primeiro plano que devolve uma URL de upload). Essa URL vale por
/// dias e não depende mais do login, então o Android pode subir os arquivos
/// sozinho, em segundo plano, mesmo com o app fechado, mostrando uma notificação.
class BackupService {
  static const grupo = 'backup';

  /// Liga o motor de upload. Chamar uma vez no início do app.
  static Future<void> init() async {
    FileDownloader().configureNotificationForGroup(
      grupo,
      running: const TaskNotification(
          'Limpa Memória', 'Subindo backup: {numFinished} de {numTotal}'),
      complete:
          const TaskNotification('Limpa Memória', 'Backup concluído ✓'),
      error: const TaskNotification(
          'Limpa Memória', 'Backup interrompido, reabra o app pra continuar'),
      progressBar: true,
    );
    // Pede permissão de notificação (Android 13+); sem isso a barra de
    // progresso em segundo plano não aparece.
    await FileDownloader().permissions.request(PermissionType.notifications);
    // Banco interno do pacote: é o que faz as tarefas voltarem sozinhas depois
    // que o app é fechado ou o celular reinicia.
    await FileDownloader().trackTasks();
    await FileDownloader().resumeFromBackground();
    FileDownloader().start();
  }

  static Future<String> _acharOuCriarPasta(
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

  /// Abre uma sessão de upload retomável no Drive. Devolve (urlDaSessao, erro).
  /// Se der ruim, urlDaSessao vem null e erro traz o motivo (pra mostrar na tela).
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
      return (null, 'Drive recusou (HTTP ${resp.statusCode}).');
    } catch (e) {
      return (null, 'Falha de rede ao preparar: $e');
    }
  }

  /// Ids que já estão na fila de upload (rodando, esperando ou pra retentar).
  /// Serve pra não enfileirar de novo o que já está em andamento.
  static Future<Set<String>> idsAtivos() async {
    final ids = await FileDownloader()
        .allTaskIds(group: grupo, includeTasksWaitingToRetry: true);
    return ids.toSet();
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

  /// Cria as sessões e enfileira os uploads, um a um (o upload do primeiro já
  /// começa enquanto os outros são preparados). Devolve (enfileirados, falhas, erro).
  /// `erro` traz o primeiro motivo sistêmico de falha, pra mostrar na tela.
  static Future<(List<String>, List<String>, String?)> enfileirar({
    required GoogleSignIn gsi,
    required List<ItemBackup> itens,
  }) async {
    final enfileirados = <String>[];
    final falhas = <String>[];
    String? erro;

    final conta = gsi.currentUser;
    final client = await gsi.authenticatedClient();
    if (conta == null || client == null) {
      return (
        enfileirados,
        itens.map((e) => e.titulo).toList(),
        'Você não está conectado ao Google. Entre de novo.'
      );
    }
    final api = drive.DriveApi(client);
    final token = (await conta.authentication).accessToken;
    if (token == null) {
      return (
        enfileirados,
        itens.map((e) => e.titulo).toList(),
        'Não consegui o token do Google. Saia e entre de novo.'
      );
    }

    final String mainId;
    try {
      mainId = await _acharOuCriarPasta(api, 'Limpa Memória', null);
    } catch (e) {
      return (
        enfileirados,
        itens.map((e) => e.titulo).toList(),
        'Não consegui criar a pasta no Drive: $e'
      );
    }

    final Map<String, String> subCache = {};

    for (final item in itens) {
      try {
        var subId = subCache[item.pasta];
        if (subId == null) {
          subId = await _acharOuCriarPasta(api, item.pasta, mainId);
          subCache[item.pasta] = subId;
        }
        final asset = await AssetEntity.fromId(item.id);
        final file = await asset?.file;
        if (file == null) {
          falhas.add(item.titulo);
          erro ??= 'Não consegui abrir o arquivo "${item.titulo}".';
          continue;
        }
        final (sessao, erroSessao) = await _criarSessao(token, item.titulo, subId);
        if (sessao == null) {
          falhas.add(item.titulo);
          erro ??= erroSessao;
          continue;
        }
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
          // Drive não usa esse cabeçalho; string vazia faz o pacote omiti-lo.
          headers: const {'Content-Disposition': ''},
          group: grupo,
          updates: Updates.statusAndProgress,
          // Muitas retentativas com espera crescente: sobrevive a quedas curtas
          // de rede/DNS (o "UnknownHostException") sem desistir do arquivo.
          retries: 10,
          // Backup grande pede wifi: se o wifi cai, o upload espera ele voltar
          // em vez de falhar. Sem wifi, nada sobe (é o certo pra dezenas de GB).
          requiresWiFi: true,
          metaData: item.pasta,
        );
        // Enfileira já: o primeiro upload começa enquanto os outros preparam.
        final ok = await FileDownloader().enqueue(tarefa);
        if (ok) {
          enfileirados.add(item.id);
        } else {
          falhas.add(item.titulo);
          erro ??= 'O Android recusou enfileirar o upload.';
        }
      } catch (e) {
        falhas.add(item.titulo);
        erro ??= '$e';
      }
    }

    return (enfileirados, falhas, erro);
  }
}
