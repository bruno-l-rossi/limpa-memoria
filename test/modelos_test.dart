import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/modelos.dart';

void main() {
  test('ItemBackup ida e volta pelo mapa', () {
    final i = ItemBackup('1', 'a.jpg', 'Camera',
        path: '/p', bytes: 10, dup: '2', data: 1700000000000);
    final j = ItemBackup.fromMap(i.toMap());
    expect([j.id, j.titulo, j.pasta, j.path, j.bytes, j.dup, j.data],
        ['1', 'a.jpg', 'Camera', '/p', 10, '2', 1700000000000]);
  });

  test('job antigo sem data continua lendo', () {
    final j = ItemBackup.fromMap({'id': '1', 'titulo': 'a', 'pasta': 'P'});
    expect(j.data, 0);
    expect(j.bytes, 0);
  });

  test('MetaTarefa aceita formato antigo (nome cru da pasta)', () {
    final m = MetaTarefa.decodificar('WhatsApp Images');
    expect(m.pasta, 'WhatsApp Images');
    expect(m.cache, isFalse);
    final n = MetaTarefa.decodificar(
        MetaTarefa('P', true, 5, titulo: 't').codificar());
    expect([n.pasta, n.cache, n.bytes, n.titulo], ['P', true, 5, 't']);
  });
}
