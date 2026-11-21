import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/pastas.dart';

void main() {
  test('pasta comum continua com o mesmo nome', () {
    expect(nomePastaDrive('DCIM/Camera/'), 'Camera');
    expect(nomePastaDrive('Pictures/Screenshots/'), 'Screenshots');
    expect(nomePastaDrive('Download/'), 'Download');
    expect(nomePastaDrive('Movies/Instagram/'), 'Instagram');
    expect(nomePastaDrive(''), 'Outros');
  });

  test('WhatsApp: Sent de imagem e de vídeo viram pastas diferentes', () {
    const base = 'Android/media/com.whatsapp/WhatsApp/Media';
    expect(nomePastaDrive('$base/WhatsApp Images/'), 'WhatsApp Images');
    expect(nomePastaDrive('$base/WhatsApp Images/Sent/'),
        'WhatsApp Images › Sent');
    expect(nomePastaDrive('$base/WhatsApp Video/Sent/'),
        'WhatsApp Video › Sent');
    expect(nomePastaDrive('$base/WhatsApp Images/Private/'),
        'WhatsApp Images › Private');
  });

  test('pasta logo abaixo de pacote não leva o pacote no nome', () {
    expect(nomePastaDrive('Android/media/com.app.x/Fotos/'), 'Fotos');
  });

  test('nome antigo é o último pedaço', () {
    expect(pastaLegada('WhatsApp Video › Sent'), 'Sent');
    expect(pastaLegada('Camera'), 'Camera');
    expect(pastasPossiveis('WhatsApp Video › Sent'),
        {'WhatsApp Video › Sent', 'Sent'});
    expect(pastasPossiveis('Camera'), {'Camera'});
  });

  test('o nome antigo bate com a regra das rodadas até 17', () {
    // Antes: último pedaço do caminho. pastaLegada(nomeNovo) tem que dar isso.
    for (final c in [
      'DCIM/Camera/',
      'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/Sent/',
      'Pictures/Telegram/',
      'DCIM/Viagem 2024/Praia/',
    ]) {
      final antigo = c.split('/').where((p) => p.isNotEmpty).last;
      expect(pastaLegada(nomePastaDrive(c)), antigo, reason: c);
    }
  });
}
