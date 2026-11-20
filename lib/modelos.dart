import 'dart:convert';

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
  // + mesmo tamanho + mesmo MD5). Item com dup não é enfileirado; quando o
  // principal confirma, este é marcado como coberto pelo mesmo arquivo do Drive.
  final String dup;
  // Rodada 12: data da mídia (ms desde 1970, 0 = desconhecida). Vai pro Drive
  // como modifiedTime/createdTime: sem isso tudo ficava com a data do upload.
  final int data;

  ItemBackup(this.id, this.titulo, this.pasta,
      {this.path = '', this.bytes = 0, this.dup = '', this.data = 0});

  ItemBackup comDup(String novoDup) => ItemBackup(id, titulo, pasta,
      path: path, bytes: bytes, dup: novoDup, data: data);

  Map<String, String> toMap() => {
        'id': id,
        'titulo': titulo,
        'pasta': pasta,
        if (path.isNotEmpty) 'path': path,
        if (bytes > 0) 'bytes': '$bytes',
        if (dup.isNotEmpty) 'dup': dup,
        if (data > 0) 'data': '$data',
      };

  static ItemBackup fromMap(Map<String, String> m) => ItemBackup(
        m['id'] ?? '',
        m['titulo'] ?? 'sem nome',
        m['pasta'] ?? 'Outros',
        path: m['path'] ?? '',
        bytes: int.tryParse(m['bytes'] ?? '') ?? 0,
        dup: m['dup'] ?? '',
        data: int.tryParse(m['data'] ?? '') ?? 0,
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
  final String? md5; // md5Checksum que o Drive calculou (rodada 12)
  ArquivoDrive(this.fileId, this.nome, this.bytes, this.pasta, {this.md5});
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
