/// Nome da subpasta no Drive a partir do caminho da mídia no celular
/// (rodada 18, achado A-06b). Puro e testado em test/pastas_test.dart.
///
/// Até a rodada 17 a subpasta era só o último pedaço do caminho. Aí
/// `WhatsApp Images/Sent` e `WhatsApp Video/Sent` caíam juntas em "Sent".
/// Regra nova: último pedaço, e quando o pai NÃO é uma pasta-raiz padrão
/// do Android, o pai vem junto ("WhatsApp Images › Sent"). Assim
/// DCIM/Camera continua "Camera" e quase nada muda de nome.
library;

/// Separador entre pai e filho no nome da subpasta. "/" não pode (o Drive
/// aceita, mas confunde quem lê como caminho).
const String sepPasta = ' › ';

/// Pastas que são "raiz" no Android: não acrescentam informação ao nome.
const Set<String> _raizes = {
  'dcim',
  'pictures',
  'movies',
  'download',
  'downloads',
  'documents',
  'music',
  'recordings',
  'media', // .../WhatsApp/Media/WhatsApp Images
  'android',
};

/// Nome da subpasta no Drive pro caminho relativo (MediaStore RELATIVE_PATH).
String nomePastaDrive(String caminhoRel) {
  final partes =
      caminhoRel.split('/').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  if (partes.isEmpty) return 'Outros';
  final ultima = partes.last;
  if (partes.length < 2) return ultima;
  final pai = partes[partes.length - 2];
  if (_raizes.contains(pai.toLowerCase()) || pai.contains('.')) {
    // ".contains('.')": nome de pacote (Android/media/com.whatsapp).
    return ultima;
  }
  return '$pai$sepPasta$ultima';
}

/// Nome que a MESMA pasta tinha até a rodada 17 (só o último pedaço).
/// Serve pra achar no Drive o que subiu antes da mudança.
String pastaLegada(String pasta) {
  final i = pasta.lastIndexOf(sepPasta);
  return i < 0 ? pasta : pasta.substring(i + sepPasta.length);
}

/// Nomes em que um arquivo dessa pasta pode estar no Drive: o novo e, se
/// for diferente, o antigo.
Set<String> pastasPossiveis(String pasta) => {pasta, pastaLegada(pasta)};
