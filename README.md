# Limpa Memória

App Android que libera espaço no celular sem perder foto nem vídeo. Ele lista tuas mídias da maior pra menor, você escolhe o que subir pro Google Drive, ele confere se cabe, sobe organizando por pasta de origem, e só então apaga do celular o que já está salvo na nuvem.

## O que ele faz

- Lista fotos e vídeos por tamanho ou por data, com miniatura e prévia (vídeo toca).
- Seleção por mídia ou por pasta inteira (WhatsApp, Download, Câmera, etc.), com "selecionar tudo".
- Filtro Todos / Fora do Drive / No Drive, pra ver rápido o que ainda falta subir.
- Login com a conta Google e checagem do espaço livre no Drive.
- Backup no Drive numa pasta "Limpa Memória", com subpastas pela origem de cada arquivo.
- Backup em segundo plano: continua subindo com o app fechado ou a tela apagada, mostrando notificação de progresso.
- Parar e retomar: para deixa o que já estava subindo terminar e guarda o resto; retomar continua de onde parou, sem re-subir nada.
- Retoma de onde parou sozinho: se o app fecha ou o celular reinicia no meio, ao reabrir ele pula o que já subiu e continua (login silencioso + re-enfileiramento do que faltou).
- Aguenta queda de rede: 10 retentativas por arquivo com espera crescente, e retry em queda curta de DNS na hora de organizar as pastas.
- Ícone de drive na pasta quando todos os arquivos dentro dela já subiram (parcial mostra quantos de quantos).
- Apaga do celular só o que tem upload confirmado, em lotes e com a confirmação do próprio Android.

## Stack

Flutter (Dart). Pacotes principais: photo_manager (galeria e deleção), google_sign_in, googleapis (Drive v3), background_downloader (upload em segundo plano + notificação), shared_preferences (guarda o progresso e o cache de tamanhos), http, video_player, google_fonts.

## Como o backup aguenta carga grande (dezenas de GB, milhares de arquivos)

O motor é uma janela deslizante. Em vez de despejar os milhares de arquivos de uma vez no Android (que engasga o WorkManager e estoura o token do Google de 1h), o app mantém poucos uploads ativos por vez (6) e vai enfileirando o próximo conforme um termina. O preparo de cada arquivo (achar a subpasta, abrir o arquivo, criar a sessão no Drive) roda em paralelo numa leva, pra rede não ficar ociosa esperando o preparo do próximo.

Cada arquivo abre uma sessão de upload retomável no Drive (um POST rápido que devolve uma URL de upload válida por dias, independente do login). Essa URL vira uma tarefa do background_downloader, que o Android sobe em segundo plano. Os uploads rodam em primeiro plano (foreground service), o que remove o teto de ~9 minutos por tarefa do Android e deixa vídeo grande terminar.

A contagem é guiada pelo banco da própria biblioteca, não pelo evento ao vivo (que pode se perder num job de horas). Um sync a cada 15s pergunta o que está ativo e o que concluiu, repõe a janela e mantém o total estável do começo ao fim. O progresso (arquivos já confirmados) fica gravado no celular, mantido na memória como fonte da verdade e gravado em lote. Ao reabrir, o app reconcilia com o banco, faz login silencioso e remonta a janela com o que faltava, sem re-subir o que já está no Drive (sem duplicata).

Sobe em qualquer conexão. No wifi economiza dados; em dados móveis também sobe.

## Desempenho em abertura

O tamanho de cada arquivo fica em cache por id. A primeira leitura da galeria mede os arquivos uma vez; as aberturas seguintes só leem o que apareceu de novo, então num celular com milhares de arquivos a abertura fica quase instantânea em vez de reescanear tudo.

## Limites conhecidos

- O background_downloader não pausa um upload no meio. O "parar" do app interrompe os que ainda não começaram e deixa os que já estavam subindo terminarem; ele não corta um arquivo pela metade.
- O número exato "X de Y" e a barra de % do total ficam no banner dentro do app. A notificação do sistema é estática (sem placeholder e sem notificar arquivo a arquivo) de propósito, porque os contadores do background_downloader só enxergam as poucas tarefas da janela, não o total real da sessão.
- Apagar do celular acontece em lotes (limite do Android pra muitos arquivos de uma vez), então o Android pede confirmação em algumas levas quando a limpeza é grande.

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
