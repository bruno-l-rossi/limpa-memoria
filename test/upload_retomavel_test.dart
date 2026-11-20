import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:limpa_memoria/upload_retomavel.dart';

void main() {
  test('proximoByte', () {
    expect(proximoByte(null), 0);
    expect(proximoByte('bytes=0-1048575'), 1048576);
    expect(proximoByte('lixo'), 0);
  });

  test('fimDaParte', () {
    expect(fimDaParte(0, 100, parte: 40), 39);
    expect(fimDaParte(80, 100, parte: 40), 99);
  });

  late Directory dir;
  late File arq;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('retomavel');
    arq = File('${dir.path}/video.mp4');
    await arq.writeAsBytes(List.generate(100, (i) => i));
  });
  tearDown(() => dir.delete(recursive: true));

  test('queda no meio: consulta o Drive e continua do byte certo', () async {
    var recebido = 0;
    var caiu = false;
    final ranges = <String>[];
    final cliente = MockClient((req) async {
      final cr = req.headers['Content-Range'] ?? req.headers['content-range'];
      ranges.add(cr ?? '');
      if (cr!.startsWith('bytes */')) {
        return http.Response('', 308,
            headers: recebido > 0 ? {'range': 'bytes=0-${recebido - 1}'} : {});
      }
      final m = RegExp(r'bytes (\d+)-(\d+)/(\d+)').firstMatch(cr)!;
      final ini = int.parse(m.group(1)!), fim = int.parse(m.group(2)!);
      expect(ini, recebido, reason: 'mandou a partir do byte errado');
      if (ini == 40 && !caiu) {
        caiu = true;
        throw const SocketException('caiu');
      }
      recebido = fim + 1;
      if (recebido == 100) {
        return http.Response(
            '{"id":"f1","size":"100","md5Checksum":"abc"}', 200);
      }
      return http.Response('', 308,
          headers: {'range': 'bytes=0-${recebido - 1}'});
    });
    final up = UploadRetomavel(dir.path,
        cliente: cliente, parte: 40, esperaBase: Duration.zero);
    var sessoes = 0;
    final r = await up.enviar('1', arq.path, criarSessao: () async {
      sessoes++;
      return ('https://upload/s1', null);
    });
    expect(r.fim, FimUpload.ok);
    expect(r.fileId, 'f1');
    expect(sessoes, 1);
    expect(ranges.where((x) => x.startsWith('bytes */')).length, 1);
    expect(await up.jaEnviado('1'), 0); // sessão esquecida no fim
  });

  test('app fechou: nova instância retoma a sessão salva', () async {
    var recebido = 0;
    var bloquear = true;
    MockClient cliente() => MockClient((req) async {
          final cr = req.headers['Content-Range'] ?? req.headers['content-range'];
          if (cr!.startsWith('bytes */')) {
            return http.Response('', 308,
                headers: {'range': 'bytes=0-${recebido - 1}'});
          }
          final m = RegExp(r'bytes (\d+)-(\d+)/').firstMatch(cr)!;
          recebido = int.parse(m.group(2)!) + 1;
          if (recebido == 100) return http.Response('{"id":"f9"}', 200);
          return http.Response('', 308,
              headers: {'range': 'bytes=0-${recebido - 1}'});
        });
    final a = UploadRetomavel(dir.path,
        cliente: cliente(), parte: 40, esperaBase: Duration.zero);
    final r1 = await a.enviar('1', arq.path,
        criarSessao: () async => ('https://upload/s', null),
        cancelado: () {
          // deixa a primeira parte ir e "fecha o app"
          if (recebido >= 40 && bloquear) return true;
          return false;
        });
    expect(r1.fim, FimUpload.cancelado);
    expect(await a.jaEnviado('1'), 40);
    bloquear = false;
    final b = UploadRetomavel(dir.path,
        cliente: cliente(), parte: 40, esperaBase: Duration.zero);
    var criou = false;
    final r2 = await b.enviar('1', arq.path, criarSessao: () async {
      criou = true;
      return ('https://upload/nova', null);
    });
    expect(r2.fim, FimUpload.ok);
    expect(criou, isFalse, reason: 'devia reaproveitar a sessão salva');
  });

  test('sessão expirada: recomeça com sessão nova', () async {
    final cliente = MockClient((req) async => http.Response('', 404));
    final up = UploadRetomavel(dir.path,
        cliente: cliente, parte: 40, esperaBase: Duration.zero);
    final r = await up.enviar('1', arq.path,
        criarSessao: () async => ('https://upload/s', null));
    expect(r.fim, FimUpload.sessaoInvalida);
  });
}
