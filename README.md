# Limpa Memória

App Android que libera espaço no celular sem perder foto nem vídeo. Ele lista tuas mídias da maior pra menor, você escolhe o que subir pro Google Drive, ele confere se cabe, sobe organizando por pasta de origem, e só então apaga do celular o que já está salvo na nuvem.

## O que ele faz

- Lista fotos e vídeos por tamanho ou por data, com miniatura e prévia (vídeo toca).
- Seleção por mídia ou por pasta inteira (WhatsApp, Download, Câmera, etc.), com "selecionar tudo".
- Login com a conta Google e checagem do espaço livre no Drive.
- Backup no Drive numa pasta "Limpa Memória", com subpastas pela origem de cada arquivo.
- Apaga do celular só o que tem upload confirmado, com a confirmação do próprio Android.

## Stack

Flutter (Dart). Pacotes principais: photo_manager (galeria e deleção), google_sign_in, googleapis (Drive v3), video_player, google_fonts.

## Rodando localmente

Precisa do Flutter instalado e de um Android (ou emulador com Google Play).

    flutter pub get
    flutter run

## Configuração do Google (uma vez)

O login e o Drive dependem de uma credencial OAuth no Google Cloud:

- Projeto no Google Cloud com a Google Drive API ativada.
- Credencial OAuth do tipo Android, com pacote com.rideblan.limpa_memoria e o SHA-1 da chave de assinatura.
- Escopo drive.file: o app só acessa o que ele mesmo cria.
- Em modo de teste, cada usuário precisa estar na lista de usuários de teste.

## Gerando o instalador

    flutter build apk --release

O APK sai em build/app/outputs/flutter-apk/app-release.apk.

## Limitações

App em modo de teste, não publicado. Só usuários de teste cadastrados conseguem logar, e o login pode pedir pra refazer de tempos em tempos.
