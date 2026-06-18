# Limpa Memória

App Android que libera espaço no celular sem perder foto nem vídeo. Ele lista tuas mídias da maior pra menor, você escolhe o que subir pro Google Drive, ele confere se cabe, sobe organizando por pasta de origem, e só então apaga do celular o que já está salvo na nuvem.

## O que ele faz

- Lista fotos e vídeos por tamanho ou por data, com miniatura e prévia (vídeo toca).
- Seleção por mídia ou por pasta inteira (WhatsApp, Download, Câmera, etc.), com "selecionar tudo".
- Login com a conta Google e checagem do espaço livre no Drive.
- Backup no Drive numa pasta "Limpa Memória", com subpastas pela origem de cada arquivo.
- Backup em segundo plano: continua subindo com o app fechado ou a tela apagada, mostrando notificação de progresso.
- Retoma de onde parou: se o app fecha ou o celular reinicia no meio, ao reabrir ele pula o que já subiu e continua sozinho (login silencioso + re-enfileiramento do que faltou).
- Aguenta queda de rede: 10 retentativas por arquivo com espera crescente, e exige wifi (se o wifi cai, o upload espera ele voltar em vez de falhar).
- Apaga do celular só o que tem upload confirmado, com a confirmação do próprio Android.

## Stack

Flutter (Dart). Pacotes principais: photo_manager (galeria e deleção), google_sign_in, googleapis (Drive v3), background_downloader (upload em segundo plano + notificação), shared_preferences (guarda o progresso), http, video_player, google_fonts.

## Como o backup aguenta arquivo grande e job longo

Cada arquivo abre uma sessão de upload retomável no Drive (um POST rápido que devolve uma URL de upload válida por dias, independente do login). Essa URL vira uma tarefa do background_downloader, que o Android sobe em segundo plano via WorkManager. As tarefas enfileiradas persistem no próprio Android, então o app sendo morto ou o celular reiniciado não perde a fila.

O progresso (lista de arquivos já confirmados) fica gravado no celular com shared_preferences, mantido na memória como fonte da verdade e gravado em lote (e na hora em que o app vai pro fundo). Ao reabrir, o app faz login silencioso e re-enfileira o que o backup pedia mas ainda não subiu nem está na fila, cobrindo arquivos que falharam de vez ou se perderam num fechamento forçado.

Requer wifi: para backups grandes, se o wifi cai o upload espera ele voltar em vez de falhar. Em dados móveis, nada sobe (proposital).

Limite conhecido: o background_downloader não pausa upload e o Android dá ~9 min por arquivo. Um arquivo único que precise de mais que isso pode falhar; as 10 retentativas e o re-enfileiramento ao reabrir tendem a recuperá-lo. Para galerias normais, com muitos arquivos, não atrapalha.

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
