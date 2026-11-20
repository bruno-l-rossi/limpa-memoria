import 'modelos.dart';

/// Decisão de "pode apagar do celular?" por arquivo. Pura e testada
/// (test/verificacao_apagar_test.dart): é a regra que protege contra perda.

/// Um arquivo do celular candidato a sair.
class CandidatoApagar {
  final String id;
  final String titulo;
  final String pasta;
  final int bytesAgora; // tamanho no celular agora (0 = desconhecido)
  final String? fileId; // id no Drive gravado quando subiu
  final int? bytesEnviados; // tamanho gravado quando subiu
  final bool verificado; // MD5 já conferido contra o Drive quando subiu
  final String? md5Local; // calculado agora (só pra quem não é verificado)
  const CandidatoApagar({
    required this.id,
    required this.titulo,
    required this.pasta,
    required this.bytesAgora,
    this.fileId,
    this.bytesEnviados,
    this.verificado = false,
    this.md5Local,
  });
}

enum MotivoFica { naoAchado, tamanho, semMd5, md5Diferente }

class ResultadoApagar {
  final List<String> pode;
  final Map<String, MotivoFica> fica;
  const ResultadoApagar(this.pode, this.fica);
}

/// Precisa de MD5 local antes de decidir? (não verificado e até o teto)
bool precisaMd5(CandidatoApagar c, int tetoMd5) =>
    !c.verificado && c.bytesAgora > 0 && c.bytesAgora <= tetoMd5;

/// Regras:
/// 1. Achar o arquivo no Drive: pelo fileId gravado; sem fileId, por
///    nome+pasta+tamanho (cada arquivo do Drive cobre UM do celular).
/// 2. Tamanho do Drive = tamanho no celular agora = tamanho enviado.
/// 3. Integridade: já verificado no upload, OU acima do teto de MD5 (vale o
///    tamanho, como sempre foi), OU MD5 local igual ao MD5 do Drive.
///    Sem MD5 de um dos lados = fica no celular.
ResultadoApagar decidirApagar(
    List<CandidatoApagar> candidatos, List<ArquivoDrive> noDrive,
    {required int tetoMd5}) {
  final porId = <String, ArquivoDrive>{};
  final porChave = <String, List<ArquivoDrive>>{};
  for (final a in noDrive) {
    porId[a.fileId] = a;
    porChave.putIfAbsent('${a.nome}|${a.pasta}|${a.bytes}', () => []).add(a);
  }
  final usados = <String>{}; // fileIds já casados por chave
  final pode = <String>[];
  final fica = <String, MotivoFica>{};

  for (final c in candidatos) {
    ArquivoDrive? a;
    if (c.fileId != null) {
      a = porId[c.fileId];
    } else if (c.bytesAgora > 0) {
      final lista = porChave['${c.titulo}|${c.pasta}|${c.bytesAgora}'];
      if (lista != null) {
        for (final x in lista) {
          if (!usados.contains(x.fileId)) {
            a = x;
            usados.add(x.fileId);
            break;
          }
        }
      }
    }
    if (a == null) {
      fica[c.id] = MotivoFica.naoAchado;
      continue;
    }
    final esperado = c.bytesAgora > 0 ? c.bytesAgora : c.bytesEnviados;
    if ((esperado != null && a.bytes != esperado) ||
        (c.bytesEnviados != null && a.bytes != c.bytesEnviados)) {
      fica[c.id] = MotivoFica.tamanho;
      continue;
    }
    if (c.verificado || !precisaMd5(c, tetoMd5)) {
      pode.add(c.id);
      continue;
    }
    final ml = c.md5Local, md = a.md5;
    if (ml == null || ml.isEmpty || md == null || md.isEmpty) {
      fica[c.id] = MotivoFica.semMd5;
    } else if (ml.toLowerCase() != md.toLowerCase()) {
      fica[c.id] = MotivoFica.md5Diferente;
    } else {
      pode.add(c.id);
    }
  }
  return ResultadoApagar(pode, fica);
}
