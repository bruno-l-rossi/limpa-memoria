import 'modelos.dart';
import 'pastas.dart';

/// Manutenção do que já está no Drive (rodada 18): organizar pastas depois
/// da mudança de nome e corrigir a data dos backups antigos. Só a parte
/// pura (decidir o quê); as chamadas à API ficam no BackupService.
/// Testes em test/manutencao_drive_test.dart.

/// Um item do celular que já subiu, com o fileId gravado (se houver).
typedef ItemEnviado = ({ItemBackup item, String? fileId});

/// Casa cada item com o arquivo dele no Drive. Pelo fileId; sem fileId, por
/// nome+tamanho na pasta nova ou na antiga (1 arquivo do Drive cobre 1 item).
/// Devolve id do item -> arquivo no Drive. Item sem par fica de fora.
Map<String, ArquivoDrive> casarComDrive(
    List<ItemEnviado> itens, List<ArquivoDrive> noDrive) {
  final porId = {for (final a in noDrive) a.fileId: a};
  final porChave = <String, List<ArquivoDrive>>{};
  for (final a in noDrive) {
    porChave.putIfAbsent('${a.nome}|${a.pasta}|${a.bytes}', () => []).add(a);
  }
  final usados = <String>{};
  final res = <String, ArquivoDrive>{};
  // 1ª passada: fileId (exato). Reserva os arquivos antes do casamento por
  // nome, senão um item sem fileId podia "roubar" o arquivo de outro.
  for (final e in itens) {
    final fid = e.fileId;
    if (fid == null) continue;
    final a = porId[fid];
    if (a != null && usados.add(a.fileId)) res[e.item.id] = a;
  }
  for (final e in itens) {
    if (e.fileId != null || e.item.bytes <= 0) continue;
    ArquivoDrive? achado;
    for (final p in pastasPossiveis(e.item.pasta)) {
      for (final a in porChave['${e.item.titulo}|$p|${e.item.bytes}'] ??
          const <ArquivoDrive>[]) {
        if (!usados.contains(a.fileId)) {
          achado = a;
          break;
        }
      }
      if (achado != null) break;
    }
    if (achado != null) {
      usados.add(achado.fileId);
      res[e.item.id] = achado;
    }
  }
  return res;
}

/// Um arquivo pra trocar de pasta no Drive.
typedef Movimento = ({String fileId, String de, String paraPasta});

/// O que está na pasta de nome antigo e deve ir pra pasta de nome novo.
List<Movimento> planejarMovimentos(
    List<ItemEnviado> itens, List<ArquivoDrive> noDrive) {
  final casados = casarComDrive(itens, noDrive);
  final res = <Movimento>[];
  for (final e in itens) {
    final a = casados[e.item.id];
    if (a == null || a.pasta == e.item.pasta || a.paiId == null) continue;
    // Só move o que está na pasta ANTIGA dessa mesma pasta (nunca de uma
    // pasta qualquer pra outra).
    if (a.pasta != pastaLegada(e.item.pasta)) continue;
    res.add((fileId: a.fileId, de: a.paiId!, paraPasta: e.item.pasta));
  }
  return res;
}

/// Data aceitável pra mandar pro Drive (mesma regra do upload): depois de
/// 1990 e no máximo 2 dias no futuro.
bool dataValida(int dataMs, {DateTime? agora}) {
  final minimo = DateTime.utc(1990).millisecondsSinceEpoch;
  final maximo = (agora ?? DateTime.now())
      .add(const Duration(days: 2))
      .millisecondsSinceEpoch;
  return dataMs > minimo && dataMs < maximo;
}

/// A data no Drive precisa ser trocada pela data da mídia? Tolera 2 s (o
/// Drive guarda milissegundos, a galeria às vezes só segundos).
bool precisaCorrigirData(DateTime? noDrive, int dataMs, {DateTime? agora}) {
  if (!dataValida(dataMs, agora: agora)) return false;
  if (noDrive == null) return true;
  return (noDrive.millisecondsSinceEpoch - dataMs).abs() > 2000;
}

/// Um arquivo do Drive com a data certa a gravar.
typedef CorrecaoData = ({String fileId, DateTime data});

List<CorrecaoData> planejarDatas(
    List<ItemEnviado> itens, List<ArquivoDrive> noDrive, {DateTime? agora}) {
  final casados = casarComDrive(itens, noDrive);
  return [
    for (final e in itens)
      if (casados[e.item.id] case final a?
          when precisaCorrigirData(a.modificado, e.item.data, agora: agora))
        (
          fileId: a.fileId,
          data: DateTime.fromMillisecondsSinceEpoch(e.item.data, isUtc: true)
        )
  ];
}
