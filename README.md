# Limpa Memória

App Android que libera espaço no celular sem perder foto nem vídeo. Ele lista tuas mídias da maior pra menor, você escolhe o que subir pro Google Drive, ele confere se cabe, sobe organizando por pasta de origem, e só então apaga do celular o que já está salvo na nuvem.

## O que ele faz

- Lista fotos e vídeos por tamanho ou por data, com miniatura e prévia (vídeo toca).
- Seleção por mídia ou por pasta inteira (WhatsApp, Download, Câmera, etc.), com "selecionar tudo".
- Login com a conta Google e checagem do espaço livre no Drive.
- Backup no Drive numa pasta "Limpa Memória", com subpastas pela origem de cada arquivo.
- Backup em segundo plano: continua subindo com o app fechado ou a tela apagada, mostrando notificação de progresso.
- Retoma de onde parou: se o app fecha ou o celular reinicia no meio, ao reabrir ele pula o que já subiu e continua sozinho.
- Apaga do celular só o que tem upload confirmado, com a confirmação do próprio Android.

## Stack

Flutter (Dart). Pacotes principais: photo_manager (galeria e deleção), google_sign_in, googleapis (Drive v3), background_downloader (upload em segundo plano + notificação), shared_preferences (guarda o progresso), http, video_player, google_fonts.

## Como o backup aguenta arquivo grande

Cada arquivo abre uma sessão de upload retomável no Drive (um POST rápido que devolve uma URL de upload válida por dias, independente do login). Essa URL vira uma tarefa do background_downloader, que o Android sobe em segundo plano. O que já terminou fica gravado no celular (shared_preferences), então reabrir nunca recomeça do zero.

Limite conhecido: o background_downloader não pausa upload e o Android dá ~9 min por arquivo. Um arquivo único que precise de mais que isso pode falhar e tentar de novo do começo (priority 0 ajuda no Android 14+). Para galerias normais, com muitos arquivos, não atrapalha.

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
