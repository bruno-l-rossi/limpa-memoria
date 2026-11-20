import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/upload_store.dart';

void main() {
  test('linha truncada (kill no meio) é ignorada', () {
    final (m, n) = parseLinhasEnviados([
      '{"id":"1","fileId":"a","bytes":10,"v":1}',
      '{"id":"2","fileId":"b"',
      '',
    ]);
    expect(n, 2);
    expect(m.keys, ['1']);
    expect(m['1'], ['a', 10, true]);
  });

  test('linha nova não apaga o que já se sabia', () {
    final (m, _) = parseLinhasEnviados([
      '{"id":"1","fileId":"a","bytes":10,"v":1}',
      '{"id":"1"}',
    ]);
    expect(m['1'], ['a', 10, true]);
  });

  test('fileId novo sem v zera a verificação', () {
    final (m, _) = parseLinhasEnviados([
      '{"id":"1","fileId":"a","v":1}',
      '{"id":"1","fileId":"b"}',
    ]);
    expect(m['1']![0], 'b');
    expect(m['1']![2], false);
  });

  test('linha antiga sem v = não verificada', () {
    final (m, _) = parseLinhasEnviados(['{"id":"1","fileId":"a","bytes":5}']);
    expect(m['1']![2], false);
  });
}
