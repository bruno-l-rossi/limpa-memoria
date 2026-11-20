# Limpa Memória

App Android que libera espaço no celular sem perder foto nem vídeo. Ele lista tuas mídias da maior pra menor, você escolhe o que subir pro Google Drive, ele confere se cabe, sobe organizando por pasta de origem, e só apaga do celular o que conferiu, um a um, que está salvo na nuvem.

## O que ele faz

- Onboarding de 3 telas na primeira vez: o que o app faz, por que pede cada permissão, conectar o Google.
- Card de missão no topo: quanto o celular tem em fotos e vídeos, quanto já está seguro no Drive e um botão "Liberar espaço" que resolve a jornada inteira.
- Sugestões prontas de backup (vídeos grandes, vídeos e fotos do WhatsApp, mais antigos que 1 ano, screenshots, downloads), cada uma com o quanto libera. Marca, confirma e o backup começa.
- Grade de fotos com seleção por toque, badge de tamanho e nuvem nos que já subiram. Com algo marcado, segurar e arrastar marca vários de uma vez; sem nada marcado, segurar abre a prévia. Também dá pra selecionar por pasta inteira.
- Filtro Todos / Fora do Drive / No Drive, pra ver rápido o que ainda falta subir.
- Login com a conta Google e checagem do espaço livre no Drive. Se a seleção não cabe, oferece subir só o que cabe (começando pelos maiores, que liberam mais espaço).
- Backup no Drive numa pasta "Limpa Memória", com subpastas pela origem de cada arquivo e a data original de cada foto/vídeo. Pastas de nome repetido levam o nome da pasta de cima ("WhatsApp Images › Sent" e "WhatsApp Video › Sent" em vez de um "Sent" só). Duplicata exata (mesmo nome, tamanho e conteúdo conferido por MD5, clássico do WhatsApp) sobe 1 vez só.
- Backup em segundo plano com DUAS camadas de acompanhamento: o banner no app (ETA e velocidade, "~2h10 restantes · 4,3 MB/s") e uma notificação do sistema com o número real ("Backup: 4.312 de 19.000") e barra de progresso.
- Ao concluir, celebra e fecha o ciclo: "N arquivos seguros no Drive. Liberar X GB do celular?", com botão de compartilhar.
- Parar e retomar: parar cancela o que está na fila do Android (o que já subiu fica salvo); retomar continua de onde parou, sem re-subir nada.
- Retoma de onde parou sozinho: se o app fecha ou o celular reinicia no meio, ao reabrir ele pula o que já subiu e continua (login silencioso + re-enfileiramento do que faltou).
- Aguenta queda de rede: 10 retentativas por arquivo com espera crescente, retry de DNS na organização das pastas, e botão "Tentar de novo" pros que falharam de vez.
- Drive encheu no meio? O app pausa sozinho com recado claro, em vez de queimar tentativas com erro genérico.
- Toggle "só no wifi" (padrão: qualquer rede; no wifi economiza dados).
- Reinstalou o app? Ele reconhece o backup anterior no Drive e não sobe nada em dobro.
- Ícone de drive na pasta quando todos os arquivos dentro dela já subiram (parcial mostra quantos de quantos).
- Integridade de verdade: em arquivos até 256 MB, o MD5 local é comparado com o que o Drive calculou; divergiu, o app apaga o corrompido da nuvem e refaz o upload sozinho.
- Apaga do celular só depois de CONFERIR no Drive, arquivo por arquivo (id + tamanho + MD5 pra quem ainda não tinha sido conferido por conteúdo). O que não conferir fica no celular; o que não estava no Drive de verdade volta pra lista do backup. Sem a permissão de localização das fotos, não apaga (o backup poderia ter ido sem o GPS). A exclusão roda em lotes com a confirmação do próprio Android e termina mostrando quanto espaço foi liberado.
- Ajustes: só no wifi, economia de bateria, aparência (automático, claro ou escuro), apagar pra lixeira do celular (Android 11+, 30 dias pra desfazer), organizar pastas no Drive, corrigir datas no Drive, histórico de backups, espaço no Drive, recarregar galeria, diagnóstico e dois modos em teste (transferência longa do Android 14+ e motor novo em partes).
- Organizar pastas no Drive: move o que subiu antes da rodada 18 pra pasta de nome novo. Corrigir datas: troca a data dos backups antigos (que ficaram com a data do envio) pela data da foto ou do vídeo.
- Filtros por Fotos/Vídeos e Fora/No Drive; pastas abrem a própria grade; lista dos arquivos que não subiram com o motivo de cada um.

## Stack

Flutter (Dart) + um canal nativo em Kotlin (MediaStore, isenção de bateria, MD5, permissão de localização, versão do Android, share e a notificação de progresso). Pacotes principais: material_ui (Material, que saiu do pacote flutter no 3.47), photo_manager 3.12 (galeria, deleção e lixeira), google_sign_in, googleapis (Drive v3), background_downloader 9.6.4+ (upload em segundo plano + notificação + UIDT), shared_preferences (flags), http, video_player. Fonte Inter embutida em assets/fonts. O progresso do backup fica em arquivos próprios do app (append + escrita atômica), não no SharedPreferences.

## Como o backup aguenta carga grande (100 GB, dezenas de milhares de arquivos)

O motor é uma janela deslizante. Em vez de despejar os milhares de arquivos de uma vez no Android (que engasga o WorkManager e estoura o token do Google de 1h), o app mantém de 8 a 80 uploads entregues ao motor por vez, limitados a 4 GB em trânsito, e vai enfileirando os próximos conforme terminam. A fila intercala os maiores (em ordem decrescente) com levas de fotos pequenas, pra rede e custo por arquivo ficarem ocupados ao mesmo tempo. O preparo roda em levas de 6 em paralelo, pra rede não ficar ociosa sem abrir dezenas de arquivos ao mesmo tempo. A janela também é o colchão pra kill: se o Android matar o app de madrugada, o que já está na fila do motor continua subindo por horas.

Cada arquivo abre uma sessão de upload retomável no Drive (um POST rápido que devolve uma URL de upload válida por dias, independente do login). Essa URL vira uma tarefa do background_downloader, que sobe em primeiro plano (foreground service), o que remove o teto de ~9 minutos por tarefa do Android e deixa vídeo grande terminar. O upload lê o arquivo direto do caminho real do MediaStore, sem copiar pro cache; quando uma cópia é inevitável, ela é apagada assim que a tarefa termina (num celular já cheio, cache crescendo seria fatal). Em job grande o app ainda sugere tomada e pede a isenção de bateria do Android, pro Doze não pausar o backup de madrugada.

A contagem é guiada pelo banco da própria biblioteca, não pelo evento ao vivo (que pode se perder num job de horas). Um tick a cada 15s reconcilia o que concluiu e repõe a janela; reconciliar e alimentar têm travas separadas, então um preparo lento não congela a contagem. Cada arquivo confirmado vira UMA LINHA em append num arquivo local (com o fileId que o Drive devolveu), então gravar progresso é barato e um kill não corrompe nada. Ao reabrir, o app reconcilia com o banco, faz login silencioso e remonta a janela com o que faltava, sem duplicata.

## Desempenho em abertura

Uma consulta só ao MediaStore (canal nativo) devolve tamanho e caminho de todas as mídias em menos de 1 segundo, mesmo com 19 mil arquivos. A galeria carrega paginada, então a primeira tela aparece em segundos.

## Modos em teste (Ajustes > Em teste)

- **Transferência longa (Android 14+)**: usa o modo UIDT do Android (job iniciado pelo usuário), feito pra envios grandes e sem o teto de 6 h por dia do serviço `dataSync` em apps que miram Android 15+. Se o Android recusar (ex.: app fora da tela), a biblioteca volta sozinha pro modo normal.
- **Motor novo**: arquivos de 64 MB pra cima sobem em partes de 16 MB pelo próprio app, com a sessão do Drive salva em disco. Rede caiu, app fechou ou Parar: na volta pergunta ao Drive quanto chegou e continua dali, em vez de recomeçar o vídeo do zero. Enquanto em teste, só anda com o app aberto.

## Organização do código

`lib/main.dart` tem só o app, os campos da Home e o ciclo de vida. O resto da Home está em partes (`part of`): `home_motor.dart` (motor do backup), `home_galeria.dart` (leitura e seleção), `home_drive.dart` (conta, apagar e manutenção do Drive) e `home_telas.dart` (pedaços de tela). Telas e componentes estão em `app_paginas.dart`, `app_midia.dart` e `app_tema.dart`. Regras puras e testadas ficam em arquivos próprios (`pastas.dart`, `manutencao_drive.dart`, `selecao.dart`, `verificacao_apagar.dart`, `selecao_backup.dart`, `sugestoes.dart` e outros).

## Testes

    flutter test

Cobrem as regras que protegem contra perda (duplicata, conferência antes de apagar, leitura do enviados.jsonl), o nome novo das pastas e a compatibilidade com o antigo, o plano de mover pastas e corrigir datas no Drive, a seleção, a montagem do backup, as sugestões, as mensagens e o upload em partes. O GitHub Actions roda `flutter analyze` e `flutter test` a cada push.

## Limites conhecidos

- O background_downloader não pausa um upload no meio. O "parar" cancela a fila do Android; um arquivo cortado no meio recomeça do zero (exceto no motor novo, que continua de onde parou).
- Com o app fechado, sobem só os arquivos que já estavam na fila do motor. Pra um backup de 100 GB ir até o fim sem toque, deixe o app aberto na tomada (o banner dá essa dica até você tocar em Entendi).
- Organizar pastas só alcança o que ainda está no celular. Arquivos que já foram apagados do celular ficam na pasta antiga (ex.: "Sent"), porque o app não tem mais como saber de onde vieram.
- Corrigir datas troca a data de modificação no Drive. A data de criação o Drive não deixa mudar depois que o arquivo existe.
- Durante o backup aparecem 2 notificações: a fixa do serviço (obrigatória, é o que tira o teto de 9 min do Android) e a de progresso com o número real, atualizada pelo app. Com o app morto, a de progresso congela; a do serviço continua.
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

## Publicar

Chave de assinatura própria, nova credencial OAuth e saída do modo de teste: passo a passo em [docs/PUBLICAR.md](docs/PUBLICAR.md).

## Gerando o instalador

    flutter build apk --release

O APK sai em build/app/outputs/flutter-apk/app-release.apk.

## Limitações

App de uso próprio, em modo de teste, sem planos de loja. Só usuários de teste cadastrados conseguem logar, e o login pode pedir pra refazer de tempos em tempos. Publicar a tela de consentimento no Google Cloud (docs/PUBLICAR.md, só a parte do OAuth) tira esse incômodo sem mexer em código.
