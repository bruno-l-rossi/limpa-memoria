import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/telemetria.dart';

void main() {
  test('faixas', () {
    final t = Telemetria();
    t.registrar(1024);
    t.registrar(10 * 1024 * 1024);
    t.registrar(300 * 1024 * 1024);
    t.registrar(2048);
    expect(t.arquivos, [2, 1, 1]);
    t.preparo(const Duration(milliseconds: 100));
    t.preparo(const Duration(milliseconds: 300));
    expect(t.preparoMedioMs, 200);
    t.zerar();
    expect(t.arquivos, [0, 0, 0]);
  });
}
