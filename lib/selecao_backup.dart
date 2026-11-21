import 'modelos.dart';

/// Regras puras de montagem do backup (testadas em test/selecao_backup_test.dart).
/// Nada aqui toca rede, disco ou tela.

/// Chave de duplicata exata. Só nome + tamanho NÃO basta (dois arquivos
/// diferentes podem ter o mesmo nome e o mesmo tamanho); por isso a chave
/// inclui o MD5 quando ele é conhecido.
String chaveDup(String titulo, int bytes, String? md5) =>
    '$titulo|$bytes|${md5 ?? ''}';

/// Marca duplicatas exatas entre os pendentes.
///
/// [jaEnviados]: chave (de [chaveDup]) -> id de um arquivo que já está no
/// Drive e pode servir de principal.
/// [md5]: id -> MD5 local. Item sem MD5 conhecido NUNCA vira duplicata
/// (sobe normalmente). Isso evita apagar do celular um arquivo diferente que
/// só por acaso tinha o mesmo nome e tamanho de outro.
///
/// Devolve os pendentes (com `dup` preenchido nas duplicatas) e quantas são.
(List<ItemBackup>, int) marcarDuplicatas(
  List<ItemBackup> pendentes, {
  Map<String, String> jaEnviados = const {},
  Map<String, String> md5 = const {},
}) {
  final principal = Map<String, String>.of(jaEnviados);
  var duplicatas = 0;
  final saida = <ItemBackup>[];
  for (final it in pendentes) {
    final m = md5[it.id];
    if (it.bytes <= 0 || m == null || m.isEmpty) {
      saida.add(it.comDup(''));
      continue;
    }
    final chave = chaveDup(it.titulo, it.bytes, m);
    final p = principal[chave];
    if (p == null || p == it.id) {
      principal[chave] = it.id;
      saida.add(it.comDup(''));
    } else {
      duplicatas++;
      saida.add(it.comDup(p));
    }
  }
  return (saida, duplicatas);
}

/// Grupos de candidatos a duplicata: mesmo nome + mesmo tamanho, com 2 ou
/// mais membros. São só esses que precisam de MD5 pra decidir.
List<List<T>> gruposCandidatos<T>(
    Iterable<T> itens, String Function(T) titulo, int Function(T) bytes) {
  final g = <String, List<T>>{};
  for (final it in itens) {
    final b = bytes(it);
    if (b <= 0) continue;
    g.putIfAbsent('${titulo(it)}|$b', () => []).add(it);
  }
  return [
    for (final l in g.values)
      if (l.length > 1) l
  ];
}

/// Escolhe o que cabe no Drive, maiores primeiro (liberam mais espaço).
/// Devolve (os que cabem, soma dos bytes deles).
(List<ItemBackup>, int) apararPraCaber(List<ItemBackup> soSobem, int livre,
    {int margem = 200 * 1024 * 1024}) {
  final orcamento = livre - margem;
  final ordenados = List<ItemBackup>.of(soSobem)
    ..sort((a, b) => b.bytes.compareTo(a.bytes));
  final cabem = <ItemBackup>[];
  var soma = 0;
  for (final it in ordenados) {
    if (it.bytes <= 0) continue;
    if (soma + it.bytes > orcamento) continue;
    soma += it.bytes;
    cabem.add(it);
  }
  return (cabem, soma);
}

/// Depois de aparar: ficam os aparados + as duplicatas cujo principal ficou
/// (ou já está no Drive).
List<ItemBackup> manterAparados(List<ItemBackup> pendentes,
    Set<String> idsAparados, bool Function(String id) jaEnviado) {
  return pendentes
      .where((it) => it.dup.isEmpty
          ? idsAparados.contains(it.id)
          : (idsAparados.contains(it.dup) || jaEnviado(it.dup)))
      .toList();
}

/// Ordem da fila de upload.
///
/// Antes era "maiores primeiro" estrito: o começo eram só vídeos (rede cheia,
/// poucos arquivos por vez) e o fim, milhares de fotos (custo por arquivo,
/// rede ociosa). Intercalar mantém os dois gargalos ocupados ao mesmo tempo:
/// a cada [grandesPorLeva] arquivos grandes entram [pequenosPorLeva] pequenos.
/// Os grandes continuam em ordem decrescente (liberam espaço mais cedo).
List<ItemBackup> ordenarFila(Iterable<ItemBackup> itens,
    {bool intercalar = true,
    int limitePequeno = 8 * 1024 * 1024,
    int grandesPorLeva = 1,
    int pequenosPorLeva = 8}) {
  final todos = itens.toList()..sort((a, b) => b.bytes.compareTo(a.bytes));
  if (!intercalar) return todos;
  final grandes = todos.where((i) => i.bytes >= limitePequeno).toList();
  final pequenos = todos.where((i) => i.bytes < limitePequeno).toList();
  final saida = <ItemBackup>[];
  var g = 0, p = 0;
  while (g < grandes.length || p < pequenos.length) {
    for (var k = 0; k < grandesPorLeva && g < grandes.length; k++) {
      saida.add(grandes[g++]);
    }
    for (var k = 0; k < pequenosPorLeva && p < pequenos.length; k++) {
      saida.add(pequenos[p++]);
    }
  }
  return saida;
}
