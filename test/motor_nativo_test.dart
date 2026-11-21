import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/modelos.dart';
import 'package:limpa_memoria/motor_nativo.dart';

void main() {
  late Directory tmp;
  late ArquivosMotor arq;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('motor_');
    arq = ArquivosMotor(tmp.path);
  });
  tearDown(() => tmp.delete(recursive: true));

  test('fila sai no formato que o Kotlin lê', () async {
    await arq.escreverFila([
      ItemNativo(
          ItemBackup('1', 'a.jpg', 'Camera',
              path: '/sd/a.jpg', bytes: 10, data: 123),
          'pai1'),
    ]);
    final j = jsonDecode(
        await File('${tmp.path}/motor/fila.json').readAsString()) as Map;
    final it = (j['itens'] as List).single as Map;
    expect(it['id'], '1');
    expect(it['paiId'], 'pai1');
    expect(it['path'], '/sd/a.jpg');
    expect(it['bytes'], 10);
    expect(it['data'], 123);
  });

  test('lê resultados aos poucos e guarda a linha incompleta pra depois',
      () async {
    final f = File('${tmp.path}/motor/resultados.jsonl');
    await f.parent.create(recursive: true);
    await f.writeAsString(
        '{"id":"1","ok":true,"fileId":"f1","bytes":10,"verificado":true}\n'
        '{"id":"2","ok":false,"erro":"drive_cheio","definitivo":false}\n'
        '{"id":"3","ok":tr');
    final (r1, off1) = await arq.lerResultados(0);
    expect(r1.map((e) => e.id), ['1', '2']);
    expect(r1.first.fileId, 'f1');
    expect(r1.first.verificado, isTrue);
    expect(r1[1].driveCheio, isTrue);
    await f.writeAsString('ue,"fileId":"f3"}\n', mode: FileMode.append);
    final (r2, off2) = await arq.lerResultados(off1);
    expect(r2.single.id, '3');
    expect(r2.single.ok, isTrue);
    final (r3, off3) = await arq.lerResultados(off2);
    expect(r3, isEmpty);
    expect(off3, off2);
  });

  test('arquivo recriado (menor que o offset): lê do começo', () async {
    final f = File('${tmp.path}/motor/resultados.jsonl');
    await f.parent.create(recursive: true);
    await f.writeAsString('{"id":"9","ok":true}\n');
    final (r, _) = await arq.lerResultados(99999);
    expect(r.single.id, '9');
  });

  test('estado: "ativo" velho não conta como vivo', () {
    final agora = DateTime(2026, 11, 21, 12);
    final e = EstadoNativo.de(jsonEncode({
      'ativo': true,
      't': agora.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
      'total': 10,
      'feitos': 4,
    }))!;
    expect(e.vivo(agora), isFalse);
    final e2 = EstadoNativo.de(jsonEncode({
      'ativo': true,
      't': agora.millisecondsSinceEpoch,
    }))!;
    expect(e2.vivo(agora), isTrue);
    expect(e.feitos, 4);
  });

  test('linha quebrada não derruba a leitura', () {
    expect(ResultadoNativo.de('lixo'), isNull);
    expect(ResultadoNativo.de('{"ok":true}'), isNull);
  });

  test('fila leva até onde o app leu; geração vem da 1ª linha', () async {
    await arq.escreverFila(const [], lido: (geracao: 7, offset: 300));
    final j = jsonDecode(
        await File('${tmp.path}/motor/fila.json').readAsString()) as Map;
    expect(j['lido'], {'geracao': 7, 'offset': 300});
    expect(await arq.geracao(), -1); // sem resultados ainda
    final f = File('${tmp.path}/motor/resultados.jsonl');
    await f.writeAsString('{"geracao":1790000000000}\n{"id":"1","ok":true}\n');
    expect(await arq.geracao(), 1790000000000);
    final (r, _) = await arq.lerResultados(0);
    expect(r.single.id, '1'); // o cabeçalho não vira resultado
    await f.writeAsString('{"id":"2","ok":true}\n');
    expect(await arq.geracao(), 0); // arquivo antigo, sem cabeçalho
  });
}
