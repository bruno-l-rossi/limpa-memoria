import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/selecao.dart';

class _M {
  final String id;
  final String pasta;
  int bytes;
  _M(this.id, this.pasta, this.bytes);
}

Selecao<_M> _nova() =>
    Selecao<_M>(bytesDe: (m) => m.bytes, grupoDe: (m) => m.pasta);

void main() {
  test('soma e conta por pasta acompanham add/remove', () {
    final a = _M('a', 'Camera', 10), b = _M('b', 'Camera', 5);
    final c = _M('c', 'Sent', 7);
    final s = _nova()..addAll([a, b, c]);
    expect(s.length, 3);
    expect(s.bytes, 22);
    expect(s.noGrupo('Camera'), 2);
    s.remove(b);
    expect(s.bytes, 17);
    expect(s.noGrupo('Camera'), 1);
    s.add(a); // repetido não conta 2x
    expect(s.bytes, 17);
    s.removeWhere((m) => m.pasta == 'Sent');
    expect(s.noGrupo('Sent'), 0);
    expect(s.bytes, 10);
    s.clear();
    expect(s.bytes, 0);
    expect(s.isEmpty, isTrue);
  });

  test('tamanho que muda depois: remover não deixa a soma negativa', () {
    final a = _M('a', 'X', 0);
    final s = _nova()..add(a);
    a.bytes = 100; // leitura de tamanho chegou depois
    s.remove(a);
    expect(s.bytes, 0);
  });

  test('recalcular pega os tamanhos novos', () {
    final a = _M('a', 'X', 0);
    final s = _nova()..add(a);
    a.bytes = 100;
    s.recalcular();
    expect(s.bytes, 100);
    s.removeAll([a]);
    expect(s.bytes, 0);
  });
}
