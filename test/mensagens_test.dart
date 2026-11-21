import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/mensagens.dart';

void main() {
  test('erro técnico vira texto claro', () {
    expect(mensagemAmigavel('SocketException: Failed host lookup'),
        contains('internet'));
    expect(mensagemAmigavel('drive-cheio'), contains('Drive está cheio'));
    expect(mensagemAmigavel('PlatformException(sign_in_canceled)'),
        'Login cancelado.');
    expect(mensagemAmigavel(null), contains('Tente de novo'));
    expect(mensagemAmigavel('xpto estranho'), contains('Diagnóstico'));
  });
}
