import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/modelos.dart';
import 'package:limpa_memoria/selecao_backup.dart';

ItemBackup it(String id, String nome, int bytes, {String pasta = 'P'}) =>
    ItemBackup(id, nome, pasta, bytes: bytes, path: '/x/$id');

void main() {
  group('marcarDuplicatas', () {
    test('mesmo nome e tamanho mas MD5 diferente: os dois sobem', () {
      final (r, n) = marcarDuplicatas([it('1', 'IMG.jpg', 100), it('2', 'IMG.jpg', 100)],
          md5: {'1': 'aaa', '2': 'bbb'});
      expect(n, 0);
      expect(r.every((e) => e.dup.isEmpty), isTrue);
    });

    test('sem MD5 nunca vira duplicata', () {
      final (r, n) = marcarDuplicatas([it('1', 'IMG.jpg', 100), it('2', 'IMG.jpg', 100)]);
      expect(n, 0);
      expect(r.every((e) => e.dup.isEmpty), isTrue);
    });

    test('MD5 igual: a segunda é coberta pela primeira', () {
      final (r, n) = marcarDuplicatas([it('1', 'IMG.jpg', 100), it('2', 'IMG.jpg', 100)],
          md5: {'1': 'aaa', '2': 'aaa'});
      expect(n, 1);
      expect(r[0].dup, '');
      expect(r[1].dup, '1');
    });

    test('arquivo já enviado serve de principal', () {
      final (r, n) = marcarDuplicatas([it('2', 'IMG.jpg', 100)],
          jaEnviados: {chaveDup('IMG.jpg', 100, 'aaa'): '9'}, md5: {'2': 'aaa'});
      expect(n, 1);
      expect(r.single.dup, '9');
    });

    test('limpa dup antigo vindo do job', () {
      final antigo = it('2', 'IMG.jpg', 100).comDup('1');
      final (r, _) = marcarDuplicatas([antigo]);
      expect(r.single.dup, '');
    });
  });

  test('gruposCandidatos só devolve grupos com 2+', () {
    final g = gruposCandidatos<ItemBackup>(
        [it('1', 'a', 1), it('2', 'a', 1), it('3', 'b', 1), it('4', 'a', 2)],
        (i) => i.titulo,
        (i) => i.bytes);
    expect(g.length, 1);
    expect(g.single.map((e) => e.id), ['1', '2']);
  });

  test('apararPraCaber pega os maiores que cabem, com margem', () {
    final mb = 1024 * 1024;
    final (cabem, soma) = apararPraCaber(
        [it('a', 'a', 100 * mb), it('b', 'b', 300 * mb), it('c', 'c', 50 * mb)],
        600 * mb);
    // orçamento = 600 - 200 = 400 MB: b (300) + a (100) = 400, c não cabe
    expect(cabem.map((e) => e.id), ['b', 'a']);
    expect(soma, 400 * mb);
  });

  test('manterAparados mantém duplicatas de principal mantido ou já enviado', () {
    final l = [
      it('1', 'a', 1),
      it('2', 'a', 1).comDup('1'),
      it('3', 'b', 1).comDup('9'),
      it('4', 'c', 1).comDup('5'),
      it('5', 'c', 1),
    ];
    final r = manterAparados(l, {'1'}, (id) => id == '9');
    expect(r.map((e) => e.id), ['1', '2', '3']);
  });

  group('ordenarFila', () {
    final mb = 1024 * 1024;
    final itens = [
      it('g1', 'g1', 500 * mb),
      it('p1', 'p1', 2 * mb),
      it('g2', 'g2', 900 * mb),
      it('p2', 'p2', 3 * mb),
      it('p3', 'p3', 1 * mb),
    ];
    test('sem intercalar: maiores primeiro', () {
      expect(ordenarFila(itens, intercalar: false).map((e) => e.id),
          ['g2', 'g1', 'p2', 'p1', 'p3']);
    });
    test('intercalando: 1 grande, até 2 pequenos', () {
      expect(
          ordenarFila(itens, pequenosPorLeva: 2).map((e) => e.id),
          ['g2', 'p2', 'p1', 'g1', 'p3']);
    });
    test('não perde nem repete item', () {
      final r = ordenarFila(itens);
      expect(r.map((e) => e.id).toSet().length, itens.length);
      expect(r.length, itens.length);
    });
  });
}
