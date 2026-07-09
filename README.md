# Limpa Memória

App Android que libera espaço no celular sem perder foto nem vídeo. Ele lista tuas mídias da maior pra menor, você escolhe o que subir pro Google Drive, ele confere se cabe, sobe organizando por pasta de origem, e só apaga do celular o que conferiu, um a um, que está salvo na nuvem.

## O que ele faz

- Lista fotos e vídeos por tamanho ou por data, com miniatura e prévia (vídeo toca).
- Seleção por mídia ou por pasta inteira (WhatsApp, Download, Câmera, etc.), com "selecionar tudo".
- Filtro Todos / Fora do Drive / No Drive, pra ver rápido o que ainda falta subir.
- Login com a conta Google e checagem do espaço livre no Drive. Se a seleção não cabe, oferece subir só o que cabe (começando pelos maiores, que liberam mais espaço).
- Backup no Drive numa pasta "Limpa Memória", com subpastas pela origem de cada arquivo.
- Backup em segundo plano com notificação, estimativa de tempo e velocidade no banner ("~2h10 restantes · 4,3 MB/s").
- Parar e retomar: parar deixa o que já estava subindo terminar e guarda o resto; retomar continua de onde parou, sem re-subir nada.
- Retoma de onde parou sozinho: se o app fecha ou o celular reinicia no meio, ao reabrir ele pula o que já subiu e continua (login silencioso + re-enfileiramento do que faltou).
- Aguenta queda de rede: 10 retentativas por arquivo com espera crescente, retry de DNS na organização das pastas, e botão "Tentar de novo" pros que falharam de vez.
- Drive encheu no meio? O app pausa sozinho com recado claro, em vez de queimar tentativas com erro genérico.
- Toggle "só no wifi" (padrão: qualquer rede; no wifi economiza dados).
- Reinstalou o app? Ele reconhece o backup anterior no Drive e não sobe nada em dobro.
- Ícone de drive na pasta quando todos os arquivos dentro dela já subiram (parcial mostra quantos de quantos).
- Apaga do celular só depois de CONFERIR no Drive, arquivo por arquivo (id + tamanho). O que não conferir fica no celular. A exclusão roda em lotes com a confirmação do próprio Android.

## Stack

Flutter (Dart) + um canal nativo em Kotlin (MediaStore, isenção de bateria). Pacotes principais: photo_manager (galeria e deleção), google_sign_in, googleapis (Drive v3), background_downloader (upload em segundo plano + notificação), shared_preferences (flags), http, video_player, google_fonts. O progresso do backup fica em arquivos próprios do app (append + escrita atômica), não no SharedPreferences.

## Como o backup aguenta carga grande (100 GB, dezenas de milhares de arquivos)

O motor é uma janela deslizante. Em vez de despejar os milhares de arquivos de uma vez no Android (que engasga o WorkManager e estoura o token do Google de 1h), o app mantém até 40 uploads entregues ao motor por vez e vai enfileirando os próximos conforme terminam. O preparo roda em levas de 6 em paralelo, pra rede não ficar ociosa sem abrir dezenas de arquivos ao mesmo tempo. A janela de 40 também é o colchão pra kill: se o Android matar o app de madrugada, o que já está na fila do motor continua subindo por horas.

Cada arquivo abre uma sessão de upload retomável no Drive (um POST rápido que devolve uma URL de upload válida por dias, independente do login). Essa URL vira uma tarefa do background_downloader, que sobe em primeiro plano (foreground service), o que remove o teto de ~9 minutos por tarefa do Android e deixa vídeo grande terminar. O upload lê o arquivo direto do caminho real do MediaStore, sem copiar pro cache; quando uma cópia é inevitável, ela é apagada assim que a tarefa termina (num celular já cheio, cache crescendo seria fatal). Em job grande o app ainda sugere tomada e pede a isenção de bateria do Android, pro Doze não pausar o backup de madrugada.

A contagem é guiada pelo banco da própria biblioteca, não pelo evento ao vivo (que pode se perder num job de horas). Um tick a cada 15s reconcilia o que concluiu e repõe a janela; reconciliar e alimentar têm travas separadas, então um preparo lento não congela a contagem. Cada arquivo confirmado vira UMA LINHA em append num arquivo local (com o fileId que o Drive devolveu), então gravar progresso é barato e um kill não corrompe nada. Ao reabrir, o app reconcilia com o banco, faz login silencioso e remonta a janela com o que faltava, sem duplicata.

## Desempenho em abertura

Uma consulta só ao MediaStore (canal nativo) devolve tamanho e caminho de todas as mídias em menos de 1 segundo, mesmo com 19 mil arquivos. A galeria carrega paginada, então a primeira tela aparece em segundos.

## Limites conhecidos

- O background_downloader não pausa um upload no meio. O "parar" do app interrompe os que ainda não começaram e deixa os que já estavam subindo terminarem; ele não corta um arquivo pela metade.
- Com o app fechado, sobem só os até 40 arquivos que já estavam na fila do motor. Pra um backup de 100 GB ir até o fim sem toque, deixe o app aberto na tomada (o banner avisa isso).
- O número exato "X de Y" e a barra ficam no banner dentro do app. A notificação do sistema é estática de propósito, porque os contadores do background_downloader só enxergam as tarefas da janela, não o total real da sessão.
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
