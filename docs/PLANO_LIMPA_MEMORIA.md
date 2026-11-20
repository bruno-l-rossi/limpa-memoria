# PLANO — Limpa Memória (contexto + achados + fases)

## ESTADO DA EXECUÇÃO (atualizado 2026-11-20) — LEIA PRIMEIRO

Branch `rodadas-12-a-17` (a partir de `main` 85efe74). Versão 1.6.0+7.
**Rodada 18 (2026-11-20) compilada e testada na nuvem** (Flutter 3.50.1):
`flutter analyze` sem nenhum aviso, 62 testes, APK debug e release. Ainda NÃO
foi testado em aparelho: nada das rodadas 12 a 18 rodou num celular.

Decisões do Bruno (2026-11-20): app de uso próprio, sem Play Store. Pode
renomear pastas no Drive, ter lixeira, botão de corrigir datas e modo escuro.

Feito na rodada 18:
- A-06b pastas: `lib/pastas.dart`. Nome = último pedaço, com o pai na frente
  quando o pai não é raiz (`WhatsApp Images › Sent`). DCIM/Camera continua
  "Camera". Compatível: `pastaLegada` devolve o nome antigo e
  `pastasPossiveis` é usado no reconhecimento (`_reconhecerNoDrive`), no
  `acharNoDrive` (pasta antiga só se existir, sem criar) e no
  `decidirApagar`. Ajustes > Organizar pastas no Drive move o que está na
  pasta antiga (`BackupService.organizarPastas`, plano puro em
  `lib/manutencao_drive.dart`). Arquivos já apagados do celular ficam na
  pasta antiga (não dá pra saber a origem).
- A-07 lixeira: Ajustes > Apagar pra lixeira do celular (só Android 11+,
  canal nativo `sdk`). Apagar usa `PhotoManager.editor.android.moveToTrash`.
- Corrigir datas: Ajustes > Corrigir datas no Drive
  (`BackupService.corrigirDatas`): só `modifiedTime` (o Drive não deixa mudar
  `createdTime`), 4 por vez, tolera 2 s, pula data inválida.
- Modo escuro: cores viraram getters em `app_tema.dart` (`_escuro` acertado
  no `MaterialApp.builder`), Ajustes > Aparência (automático/claro/escuro,
  flag `tema_v1`). Cada `build` chama `_dependerDoTema(context)`.
- A-32: `main.dart` de 4.097 pra ~380 linhas. Home em extensões
  (`home_motor`, `home_galeria`, `home_drive`, `home_telas`; `setState` vira
  `_set` nelas). Telas em `app_paginas`, grade em `app_midia`. As `static
  const` do State viraram constantes de topo.
- A-16: `lib/selecao.dart` guarda soma e contagem por pasta na hora
  (total selecionado e estado da pasta ficaram O(1)).
- A-26 arrasto: `_GradeMidias`. Com algo marcado, segurar e arrastar marca a
  faixa; sem nada marcado, segurar abre a prévia (dica `dica_previa_v2`).
- A-27: "deixe o app aberto na tomada" saiu da notificação e dos avisos;
  ficou 1 dica no banner com "Entendi" (`dica_app_aberto_v1`) e o diálogo de
  job grande (> 5 GB).
- A-36: `lib/diario.dart`. 11 `catch (_) {}` do motor (fila, cancelar,
  achar/apagar no Drive, salvar sessão) agora registram no `eventos.log`.
- A-29: "Vídeos do WhatsApp" e "Fotos do WhatsApp" em grupos separados.
  A soma da seleção já era a união (o aviso de sobreposição já existia).
- Dependências: `material_ui` no lugar de `package:flutter/material.dart`;
  photo_manager 3.9 → 3.12; `android.builtInKotlin=true` (o caminho antigo
  quebrava a compilação do photo_manager 3.12).
- A-34 minify: nada a fazer, o Flutter já liga R8 no release.

Continua NÃO feito (e por quê):
- F4 inteira (motor sem o app aberto, google_sign_in 7, notificação única
  A-19/A-20): depende do teste de 1 noite com Transferência longa.
- A-08 teto de MD5 e A-15 galeria pela consulta nativa: precisam de medição
  em aparelho antes.
- A-35 publicar consentimento OAuth: é no Google Cloud, com o Bruno.
- Sugestão "Duplicatas exatas": fica de fora. Duplicata exata já sobe 1 vez
  só (MD5), e apagar cópia sem backup não é o papel do app.
- O aviso de KGP do photo_manager continua: o build.gradle dele ainda carrega
  o Kotlin antigo. Só uma versão nova do plugin tira.

Ordem de teste no aparelho (rodada 18 primeiro, depois a lista antiga):
1. Abrir, ver a aba Pastas: WhatsApp aparece separado por "Images › Sent" e
   "Video › Sent". Backups antigos continuam com nuvem nos itens.
2. Ajustes > Organizar pastas no Drive, conferir no Drive que o "Sent" foi
   esvaziado do que ainda está no celular.
3. Ajustes > Corrigir datas, conferir a data de um arquivo antigo no Drive.
4. Ligar lixeira, apagar 2 fotos, ver na lixeira da galeria e restaurar 1.
5. Aparência escura e automática; arrastar pra marcar.

Rodada 17, correções feitas na compilação:
- `android/`: Gradle 9.1.0 → 9.5.0, AGP 9.0.1 → 9.3.1, Kotlin 2.3.20 → 2.4.20.
  O Flutter 3.50 recusa Gradle < 9.3.1, AGP < 9.1.1 e KGP < 2.4.10.
- `upload_retomavel.dart`: `return await` nos retornos de `_fimOk`/`_invalida`
  dentro do try. Sem o await, o `finally` fechava o arquivo antes do fim e um
  erro escapava do `catch`.
- `main.dart`: `__` → `_` em 3 builders (lint novo).
- `pubspec.lock` regenerado (sai google_fonts, entra background_downloader 9.6.4).

Avisos que ficaram (não quebram nada hoje):
- `package:flutter/material.dart` está deprecado desde o Flutter 3.47 em favor
  do pacote `material_ui`. CI roda com `--no-fatal-infos`. Migrar numa rodada
  própria.
- `photo_manager` ainda aplica o Kotlin Gradle Plugin; versões futuras do
  Flutter vão recusar. Ver se sai versão com Built-in Kotlin.

No Mac do Bruno: `flutter upgrade` (precisa de Flutter >= 3.50 por causa dos
mínimos de Gradle/AGP acima). Na nuvem o build só rodou com espelho do Maven
Central (storage.googleapis.com/maven-central) e o `kotlin-dsl` trocado no SDK
local, porque Maven Central e plugins-artifacts.gradle.org estão bloqueados lá.
Isso não mexe no repo.

Feito (por achado da seção 3):
- F0: lógica pura extraída pra `lib/formatos.dart`, `selecao_backup.dart`,
  `verificacao_apagar.dart`, `sugestoes.dart`, `mensagens.dart`,
  `telemetria.dart`, `modelos.dart` (ItemBackup/ArquivoDrive/MetaTarefa saíram
  do backup_service e são reexportados por ele). Testes em `test/*_test.dart`
  (widget_test do contador removido). CI em `.github/workflows/ci.yml`.
  A-14 telemetria por faixa no Diagnóstico e no `sessoes.jsonl`. A-33 README.
- F1: A-01 duplicata só com MD5 igual (`marcarDuplicatas`, MD5 calculado só
  pros grupos nome+tamanho com 2+, diálogo cancelável `_md5DeVarios`).
  A-02/A-03 listagem pede `md5Checksum`; `enviados.jsonl` ganhou `"v":1`
  (verificado por MD5); apagar usa `decidirApagar` e calcula MD5 de quem não
  é verificado (≤256 MB); `naoAchado`/`md5Diferente` voltam pra "fora do
  Drive". A-04 canal `localizacaoMidia` + bloqueio no apagar. A-05
  `modifiedTime`/`createdTime` na sessão (`metadadosUpload`, campo `data` no
  job). NÃO feito: A-07 lixeira, A-08 teto de MD5 (sem medição), botão de
  corrigir datas antigas no Drive (pergunta aberta).
- F2: A-21 menu da conta + sair com confirmação; A-22 selecionar respeita
  filtros; A-24 login embutido em Liberar/Subir/Apagar; A-23 AppBar = conta +
  Ajustes (`AjustesPage`: wifi, bateria, histórico, espaço, recarregar,
  diagnóstico, modos em teste); A-25 telas de permissão/carregando/vazia,
  erros via `mensagemAmigavel`; A-26 filtro foto/vídeo (menu "tune"), pasta
  tristate e abre a própria grade (`_abrirPasta`), dica de prévia 1 vez,
  lista de falhas com motivo (`_mostrarFalhas`, `_motivoFalha`); A-28 tela
  "Você liberou X" + total acumulado + `HistoricoPage`; A-29/A-06a sugestões
  por caminho completo + "Tudo que falta"; A-17 miniatura pelo tamanho da
  célula; A-18 Inter embutida (google_fonts removido); A-30 parcial
  (semantics, badge 11 px, `fmtBytes(0)`="0 B"). NÃO feito: A-06b renomear
  pastas no Drive (decisão do Bruno), modo escuro.
- F3: fila intercalada (`ordenarFila`), janela 8–80 arquivos / 4 GB.
  UIDT opcional (Ajustes > Transferência longa, flag `uidt_v1`): exige
  background_downloader >= 9.6.4 porque a 9.5.5 NÃO chamava
  `setUserInitiated(true)` (virava job comum). Permissão
  `RUN_USER_INITIATED_JOBS` no manifest; o serviço já vem da lib; se o
  agendamento falhar a lib cai pro WorkManager. NÃO feito: T3.2 motor como
  ChangeNotifier, T3.3 galeria pela consulta nativa (medir antes), T3.4 os
  testes em aparelho do spike.
- F4 (parcial, desligado por padrão): `lib/upload_retomavel.dart` sobe
  arquivos >= 64 MB em partes de 16 MB com sessão salva em
  `sessoes_upload.json`, consulta `bytes */total` e continua. Ligado por
  Ajustes > Motor novo (flag `motor_nativo_v1`), integrado em `_alimentar`
  via `_enviarRetomavel` e conjunto `_emRetomavel`. Só roda com o app aberto.
  NÃO feito: job nativo em segundo plano, token sem UI, migração
  google_sign_in 7 (A-19). Decidir depois do teste do UIDT.
- F5: plataformas ios/linux/macos/windows/web removidas; assinatura de
  release lê `android/key.properties` se existir; `docs/PUBLICAR.md`
  (chave, SHA-1, OAuth, publicar consentimento, Play) e
  `docs/PRIVACIDADE.md` (rascunho). NÃO feito: modo escuro, publicar
  (depende do Bruno no Google Cloud).

Pontos de atenção pra quem compilar:
- `main.dart` levou muitas edições por script; procurar parênteses/vírgulas
  na `_CelulaMidia` (ganhou `Semantics` por fora), no `build()` (ternário
  novo no `body`) e na aba Pastas (CheckboxListTile virou ListTile).
- Testar em aparelho, nesta ordem: duplicata falsa (2 arquivos diferentes,
  mesmo nome e tamanho → os dois sobem); data no Drive; apagar com
  localização negada; apagar backup antigo (pede MD5 com barra); queda de
  rede com Motor novo num vídeo grande; uma noite com Transferência longa.

---


> Documento para IA. Leia inteiro antes de editar código. Gerado em 2026-11-15 por análise ESTÁTICA do repo (nada foi compilado, rodado ou testado em aparelho).
> Itens marcados `[HIPÓTESE]` precisam de confirmação em aparelho/doc antes de virar código. Itens `[CONFIRMADO-CÓDIGO]` foram lidos no fonte, com arquivo:linha.

## 0. Como retomar

- Repo: `github.com/bruno-l-rossi/limpa-memoria` (público), branch `main`, HEAD `85efe74` ("Rodada 11"), último commit 2026-10-29. Versão `1.4.0+5`.
- Dono: Bruno (não lê código; decide por resultado visível). Responder em pt-BR. Falar de comportamento, não de implementação.
- Convenções do repo: identificadores e comentários em português; commits "Rodada N: resumo"; versão em 2 lugares (`pubspec.yaml` `version:` e `const _versao` em `lib/main.dart:61`); comentários explicam o PORQUÊ com a rodada que introduziu.
- Build: `flutter pub get && flutter run` / `flutter build apk --release` (assina com chave DEBUG, ver A-27).
- Escopo pedido pelo Bruno: análise completa + plano faseado de UX/usabilidade e de eficiência funcional. O pedido original citava "delay do som com o visual": o Bruno mandou IGNORAR (não se aplica a este app). Não há docs de contexto além do README; o contexto abaixo foi reconstruído de README + histórico de commits + código.
- Preferências do Bruno que valem em toda sessão: ler `ABOUT ME/` da pasta Cowork antes de qualquer tarefa (não estava conectada nesta sessão, então NÃO foi lida), salvar entregas em `OUTPUTS/<projeto>/`, perguntar se o pedido estiver ambíguo, não encher linguiça.

## 1. O que é o app

App Android (Flutter + canal Kotlin) que libera espaço: lista fotos/vídeos, sobe pro Google Drive (pasta "Limpa Memória", subpasta por pasta de origem), confere e só então apaga do celular. Modo de teste OAuth, não publicado, escopo `drive.file`.

Mapa do código (só isto importa; `ios/ linux/ macos/ windows/ web/` são scaffold sem uso):

| Arquivo | Linhas | Papel |
|---|---|---|
| `lib/main.dart` | 3259 | TUDO de UI + o MOTOR do backup dentro de `_HomePageState` (janela deslizante, reconciliação, órfãos, ETA, apagar) + `OnboardingPage`, `PreviewPage`, `_CelulaMidia`, `_Thumb`, `_ThumbCache` |
| `lib/backup_service.dart` | 857 | Estático. Contexto (token+DriveApi+pasta), `enfileirarUm`, sessão retomável, listagem/cache do Drive, classificação de erro, retry |
| `lib/upload_store.dart` | 471 | Persistência: `enviados.jsonl` (append), `job.json` (atômico), `tamanhos.json`, `sessoes.jsonl`, `eventos.log` (gira em 512 KB), flags no SharedPreferences |
| `lib/nativo.dart` | 122 | Ponte MethodChannel `limpa_memoria/nativo` |
| `android/.../MainActivity.kt` | 247 | `midias` (MediaStore 1 consulta), `md5`, bateria, share, notificação de progresso |
| `test/widget_test.dart` | 30 | Teste padrão do contador do Flutter: QUEBRADO, não testa nada |

Deps travadas: background_downloader 9.5.5, photo_manager 3.9.0, google_sign_in 6.3.0 (legado), googleapis 16.0.0, video_player 2.11.1, google_fonts 8.1.0, shared_preferences, http. Dart SDK ^3.12.2.

Fluxo do motor (estado atual):
1. `_subirInterno` (main:1441): contexto → reconhece o que já está no Drive (nome|pasta|tamanho) → marca duplicatas (nome|tamanho) → checa cota → salva `job.json` → enche `_pendentes` (maiores primeiro).
2. `_tick` a cada 15 s (main:1871) = `_reconciliar` (banco da lib é a verdade) + `_alimentar` (mantém até `_janela=40` tarefas no background_downloader, preparo em levas de 6).
3. `enfileirarUm` (svc:400): POST cria sessão retomável → `UploadTask` PUT binário, `retries:10`, `Config.runInForeground` sempre (FGS `dataSync`).
4. `_concluido` (main:2098): confere tamanho + MD5 local×Drive (≤256 MB) → `_confirmarEnvio` → linha em `enviados.jsonl`.
5. `_apagarEnviados` (main:1698): lista o Drive fresco, confere fileId+tamanho (ou nome|pasta|tamanho), apaga em lotes de 800 via `PhotoManager.editor.deleteWithIds`.

## 2. Dores e caminho trilhado (reconstruído)

Histórico: R1 primeira versão → R2–R4 backup em segundo plano, retomada, estabilidade em job longo → R5–R6 janela deslizante, contagem/duplicata → R7 total estável, paralelo, parar/retomar → R8 "repaginada pra 100 GB" (canal nativo, store em arquivos, verificação antes de apagar) → R9 caminho feliz (missão, sugestões, vitória, onboarding, MD5) → R10 volume grande sem inconsistência (órfãos, token 1 h, rede) → R11 Parar sem vazamento, sem duplicata em resposta perdida, miniaturas canceláveis, ETA, diagnóstico.

Dores recorrentes (cada rodada volta nelas):
- D1. Backup de 100 GB / 20–30 mil arquivos NÃO vai até o fim sozinho: com o app morto só sobem os ≤40 da janela; o usuário precisa deixar o app aberto na tomada. É o limite nº 1 declarado no README.
- D2. Consistência sob falha: contagem errada, duplicata no Drive, órfão, evento perdido, token expirado. 7 das 11 rodadas são remendo disso.
- D3. Nunca perder arquivo: tudo gira em "só apaga o que conferiu".
- D4. Fluidez com 30 mil itens (boot, grade, rebuilds).
- D5. Jornada simples pra leigo: missão → sugestão → backup → liberar.
- D6. Login em modo de teste pede pra refazer; só usuários de teste.

Direção implícita: virar um app confiável "aperta e esquece", publicável.

Diagnóstico de raiz: D1 e boa parte de D2 têm a MESMA causa — o motor vive dentro de um widget Flutter e usa milhares de tarefas pequenas do SO como unidade de trabalho. Enquanto for assim, cada rodada troca um caso de borda por outro. As fases abaixo atacam primeiro risco de perda e ganhos baratos, depois a causa.

## 3. Achados

Severidade: P0 = risco de perda de dado/falha silenciosa; P1 = dor central ou ganho grande; P2 = melhoria; P3 = higiene.

### 3.1 Segurança do dado

- **A-01 P0 [CONFIRMADO-CÓDIGO] Duplicata por nome+tamanho pode apagar arquivo que nunca subiu.** `main:1506-1526` marca como `dup` qualquer item com mesmo `titulo|bytes` de outro (em QUALQUER pasta). `_cobrirDuplicatas`/`_confirmarEnvio` gravam o dup como enviado com o `fileId` do principal. No apagar (`main:1775-1782`) a conferência é fileId existe + tamanho bate → passa → apaga. Dois arquivos DIFERENTES com mesmo nome e tamanho (ex.: `IMG_0001` de duas câmeras, RAW/DNG de tamanho fixo) = o segundo é apagado sem nunca ter subido. Correção: só tratar como dup se MD5 local dos dois bater (`Nativo.md5` já existe); sem MD5 igual, sobe os dois.
- **A-02 P0 [CONFIRMADO-CÓDIGO] Reconhecimento no Drive só por nome|pasta|tamanho.** `_reconhecerNoDrive` (main:1399) e `acharNoDrive` (svc:642) marcam como enviado sem comparar conteúdo. A listagem não pede `md5Checksum` (svc:613 `files(id,name,size)`). Correção: pedir `md5Checksum` na listagem; gravar em `enviados.jsonl` um campo `v` (1 = MD5 conferido); no apagar, item sem `v=1` e ≤ teto passa por MD5 local × Drive antes de sair do celular (com barra de progresso).
- **A-03 P0 [CONFIRMADO-CÓDIGO] O que conclui com o app fechado entra sem conferência de integridade.** `main:1931-1943` marca `concluidosNoBanco()` como enviados com `fileId:null`, sem tamanho nem MD5. Fica coberto só pelo fallback nome|pasta|tamanho no apagar. Mesma correção de A-02 (verificação preguiçosa no apagar).
- **A-04 P0 [HIPÓTESE] Localização (GPS do EXIF) pode sumir em silêncio.** O manifest pede `ACCESS_MEDIA_LOCATION` e o `_load` pede `mediaLocation:true` (main:2221), mas ninguém confere se foi CONCEDIDA. Se negada, o Android entrega bytes sem GPS; o MD5 local é calculado sobre os mesmos bytes redigidos, então a conferência passa, e o original é apagado. Confirmar em aparelho (negar a permissão, subir foto com GPS, baixar do Drive e olhar o EXIF). Correção: checar a permissão no boot e antes do apagar; se negada, aviso bloqueante no fluxo de apagar.
- **A-05 P1 [CONFIRMADO-CÓDIGO] Data original não vai pro Drive.** Corpo da sessão (svc:804-807) só tem `name` e `parents`. No Drive tudo fica com a data do upload. Mídia sem EXIF (WhatsApp, screenshots, muitos vídeos) perde o "quando" depois que o original é apagado. Correção: mandar `modifiedTime` (e `createdTime`) no metadata; exige a data no `ItemBackup`/`job.json` (campo novo opcional, compatível).
- **A-06 P1 [CONFIRMADO-CÓDIGO] Subpasta = último segmento do caminho** (`_nomePasta`, main:2366). `WhatsApp Images/Sent` e `WhatsApp Video/Sent` viram a mesma pasta "Sent" no app e no Drive; a sugestão "WhatsApp" (main:1110, `pasta.contains('whatsapp')`) não pega "Sent"/"Private". Correção em 2 partes: (a) heurísticas de sugestão passam a usar `relativePath` inteiro — barato, sem migração; (b) mudar o nome da pasta no Drive quebra o reconhecimento de backups antigos (chave nome|pasta|tamanho) → só fazer com migração planejada; decidir com o Bruno.
- **A-07 P2 Apagar é definitivo.** `deleteWithIds` não passa pela lixeira. Em Android 11+ existe mover pra lixeira (30 dias) no photo_manager `[HIPÓTESE: confirmar API na versão 3.9]`. Trade-off: lixeira não libera espaço na hora. Oferecer como opção "modo seguro", não padrão.
- **A-08 P2** MD5 só até 256 MB (`_tetoMd5`, main:259); acima vale só o tamanho. Com MD5 nativo em thread própria dá pra subir o teto ou tirar (medir custo antes).

### 3.2 Motor / eficiência

- **A-09 P1 [CONFIRMADO-CÓDIGO] O motor morre com a tela.** Janela, fila, reconciliação e retentativa vivem em `_HomePageState`. Processo morto = só os ≤40 enfileirados sobem. Causa de D1.
- **A-10 P1 [HIPÓTESE forte] Teto de 6 h do serviço em primeiro plano `dataSync`.** Para apps que miram Android 15+, <cite index="21-1,24-1">o sistema limita quanto tempo serviços `dataSync` rodam com o app em segundo plano</cite>, e a documentação fixa esse orçamento em <cite index="17-1">6 horas a cada 24 horas</cite>; esgotado, <cite index="28-1">um novo serviço `dataSync` só inicia depois que o usuário traz o app pra frente</cite>. O app usa `Config.runInForeground, Config.always` (svc:161) + `foregroundServiceType="dataSync"` no manifest, e `targetSdk = flutter.targetSdkVersion` (provavelmente ≥35). Um job de madrugada com tela apagada bate nesse teto e para até o usuário abrir o app. Confirmar: Android do aparelho de teste, `targetSdk` efetivo, e `eventos.log` de uma noite (procurar parada ~6 h depois do início). Teste rápido documentado: <cite index="28-1">`adb shell am compat enable FGS_INTRODUCE_TIME_LIMITS <pacote>`</cite>.
- **A-11 P1 Caminho oficial pra transferência longa: UIDT.** O Android 14 criou os jobs de transferência iniciada pelo usuário, que <cite index="16-1">servem de alternativa ao serviço `dataSync` e ao novo timeout dele</cite>. O background_downloader já expõe isso: <cite index="7-1">prioridade 0 em Android 14+ com notificação configurada</cite>, e <cite index="7-1">exige a permissão `RUN_USER_INITIATED_JOBS` e a declaração do `UIDTJobService` no manifest</cite>. Armadilha: jobs UIDT <cite index="12-1">têm de ser agendados com o app visível</cite> — a janela deslizante agenda tarefa nova o tempo todo com a tela apagada, então trocar só a flag pode NÃO resolver. Precisa de spike (F3).
- **A-12 P1 [CONFIRMADO-CÓDIGO] Upload "retomável" não retoma.** Cada arquivo é 1 PUT inteiro; as 10 retentativas da lib reenviam do byte 0; `Parar` cancela tudo e abandona as sessões (svc:184). Vídeo de 4 GB que cai em 90% recomeça do zero. O protocolo do Drive permite consultar o ponto recebido com um PUT vazio e `Content-Range: bytes */total`, que <cite index="35-1">responde 308 com o intervalo já gravado</cite>. Exige uploader próprio (nativo) e guardar a URL da sessão por item; sessões abandonadas <cite index="44-1">expiram uma semana depois de criadas</cite>.
- **A-13 P1 Custo fixo por arquivo pequeno.** Cada foto = POST de sessão + PUT + 1 tarefa do WorkManager + registro no banco da lib + reconciliação. Com "maiores primeiro" o fim do job são milhares de fotos onde manda esse custo (o próprio código reconhece: `_pequenosPorSeg`, main:2480). Opções: (a) arquivo < ~5 MB sobe direto do Dart com `uploadType=multipart` (1 requisição) num pool de N, enquanto o app está vivo; (b) intercalar grandes e pequenos em vez de maiores-primeiro estrito; (c) janela por BYTES e não por contagem (40 fotos de 2 MB são um colchão de 80 MB; 40 vídeos são dezenas de GB). `[HIPÓTESE]` ganho precisa de medição (A-14). Respeitar limite de escrita do Drive por usuário `[verificar número na doc]`; o código já trata 403/429 de taxa.
- **A-14 P1 Falta medição.** `sessoes.jsonl` grava início/fim/arquivos/bytes mas nada por faixa de tamanho, nem tempo de preparo × tempo de upload, nem quantas tarefas rodam de fato em paralelo. Sem isso, A-13 é chute. Adicionar ao diário: MB/s e arquivos/s por faixa (<8 MB, 8–256 MB, >256 MB), tempo médio de `_criarSessao`, contagem de retentativas.
- **A-15 P2 [CONFIRMADO-CÓDIGO] Boot da galeria faz trabalho dobrado.** `_load` (main:2220) pagina TODOS os `AssetEntity` pelo photo_manager (500 + páginas de 2000) e em paralelo faz a consulta nativa que já devolve id/tamanho/caminho em <1 s. Estender a consulta nativa (nome, data, tipo, `RELATIVE_PATH`, duração, largura/altura) e montar os itens só com ela; criar `AssetEntity` sob demanda pra miniatura/prévia. `[HIPÓTESE]` medir o tempo atual de `_load` com 20–30 mil itens antes.
- **A-16 P2 [CONFIRMADO-CÓDIGO] Rebuild da tela inteira a cada 500 ms durante o backup.** `_agendarRefresh` → `setState` no `_HomePageState` reconstrói AppBar, card, banner, abas. Custos O(n) por build: `_pastaToda` (main:2443, `every` em cada pasta, toda build), `_totalSelecionado` (main:2431, fold na seleção toda build). Correção: motor vira `ChangeNotifier`; banner escuta sozinho; seleção guarda bytes e contagem por pasta incrementais.
- **A-17 P2 [CONFIRMADO-CÓDIGO] Miniatura 200×200 esticada.** `ThumbnailSize(200,200)` (main:131) em grade de 3 colunas num aparelho de 1080 px (célula ~350 px) fica borrada. Pedir pelo tamanho real da célula (teto ~320) e passar `cacheWidth`.
- **A-18 P2 google_fonts baixa a Inter da rede na 1ª execução** (main:34). Offline no primeiro uso = fonte errada + requisição extra. Embutir a fonte como asset.
- **A-19 P2 google_sign_in 6.x é legado.** A 7.x <cite index="57-1">separa autenticação de autorização e passa a usar o Credential Manager</cite>; <cite index="66-1">o construtor `GoogleSignIn(scopes: ...)` deixou de existir e não há migração automática</cite>. Toca `_gsi` (main:186), `_preparar`/`_renovarToken` (svc:273-326) e a extensão `authenticatedClient`. Planejar junto com F4 (o motor nativo vai precisar de token sem UI de qualquer jeito).
- **A-20 P3** Duas notificações durante o backup (serviço + progresso). Some naturalmente se o motor virar 1 job nativo com 1 notificação.

### 3.3 UX / interface

- **A-21 P1 [CONFIRMADO-CÓDIGO] Tocar no ícone da conta DESLOGA sem perguntar** (main:2538 `onPressed: _conta == null ? _login : _logout`). Toque acidental no meio de um backup derruba a conta. Trocar por menu (e-mail, espaço no Drive, sair com confirmação).
- **A-22 P1 [CONFIRMADO-CÓDIGO] "Selecionar tudo" ignora o filtro** (main:2441 `_selected.addAll(_items)`): com "Fora" ativo, seleciona também o que já está no Drive. Deve selecionar a lista filtrada visível.
- **A-23 P1 Barra superior confusa.** 4 ações sem rótulo: conta, wifi (`Icons.wifi_tethering` pra "qualquer rede" é ícone de roteador), lixeira, menu. "Apagar" existe em 3 lugares (card, banner, AppBar). Proposta: AppBar só com conta e menu; wifi vai pra uma tela "Ajustes"; apagar fica só no card/banner.
- **A-24 P1 Sem conta, "Liberar espaço" só mostra snackbar** "Entre com o Google primeiro (ícone lá em cima)" (main:1122, 1429). Deve abrir o login ali mesmo e continuar o fluxo.
- **A-25 P2 Estados vazios e de erro crus.** Carregando = texto centralizado (main:2578); permissão negada = texto sem botão pra abrir ajustes/tentar de novo (main:2231); erros mostram exceção bruta (`Falha no login: $e` main:1255, `Não consegui preparar o Drive: $e` svc:317).
- **A-26 P2 Descoberta e controle fracos na grade.** Segurar pra ver a prévia não é sinalizado; sem filtro foto/vídeo; sem seleção por arrasto; aba Pastas não abre a pasta (só checkbox, e seleção parcial aparece como desmarcada — usar `tristate`); não dá pra ver QUAIS arquivos falharam e por quê (só contagem + último erro, main:2754).
- **A-27 P2 Ruído de texto no banner.** Frase fixa "Com o app fechado sobem só os que já estão na fila do Android..." (main:2747) e a notificação "deixe o app aberto na tomada" expõem a limitação A-09 o tempo todo. Reduzir a 1 dica dispensável; some de vez com F4.
- **A-28 P2 Fechamento do ciclo sem recompensa.** Depois de apagar, só um snackbar (main:1852). Falta tela "Você liberou X GB" (o ganho que o app promete) e histórico de sessões (`sessoes.jsonl` é gravado e nunca mostrado). Diálogo de vitória sem botão Fechar quando há o que liberar (main:673-691).
- **A-29 P2 Sugestões** (main:1090): grupos se sobrepõem (a soma por grupo engana, o total está certo); faltam grupos de alto valor e baratos: "Downloads", "Vídeos do WhatsApp", "Tudo que está fora do Drive", "Duplicatas exatas". Screenshots por nome de pasta pode falhar em aparelhos com pasta traduzida `[HIPÓTESE]`.
- **A-30 P3** Sem modo escuro (cores fixas, main:18-23); sem `Semantics` nas células; badge de tamanho em 10 px; `_fmt(0)` devolve "0 MB".

### 3.4 Engenharia / higiene

- **A-31 P1 Zero testes e lógica intestável.** Regras críticas (dup, aparar pra caber, verificação do apagar, ETA, classificação de erro, parse do store) estão em métodos privados de um State. `test/widget_test.dart` é o teste do contador e falha. Sem CI. Explica por que cada rodada regrediu algo.
- **A-32 P1 `main.dart` com 3259 linhas** mistura motor e UI. Extrair antes de mexer no motor.
- **A-33 P2 README desatualizado:** diz que Parar "deixa os que já estavam subindo terminarem"; desde a R11 o código cancela tudo (main:1637-1639).
- **A-34 P2 Release assinado com chave debug** (`build.gradle.kts` `signingConfig = debug`), `description: "A new Flutter project."`, TODOs do template. Trocar a chave muda o SHA-1 → precisa de nova credencial OAuth Android.
- **A-35 P2 OAuth em modo de teste** = D6. `drive.file` tende a ser escopo não sensível, o que simplifica publicar a tela de consentimento `[verificar na doc do Google]`. Publicar o consentimento resolve "login pede pra refazer" sem código.
- **A-36 P3** Pastas de plataforma sem uso (ios, linux, macos, windows, web) poluem o repo; `catch (_) {}` silencioso em dezenas de pontos (trocar por `_ev` nos que escondem falha de motor).

## 4. Plano em fases

Regra geral: 1 fase = 1 rodada/commit ("Rodada 12: ..."), sobe versão, atualiza README. Não iniciar fase sem a anterior validada em aparelho pelo Bruno. Cada tarefa lista critério de aceite verificável por quem não lê código.

### F0 — Rede de segurança (pré-requisito, sem mudança visível)
Objetivo: poder mexer no motor sem regredir.
- T0.1 Extrair lógica pura de `main.dart` pra arquivos próprios, sem mudar comportamento: `formatos.dart` (`_fmt`, `_milhar`, `_eta`), `selecao_backup.dart` (dup, aparar pra caber, ordenação da fila), `verificacao_apagar.dart` (decisão ok/não ok por item), `sugestoes.dart`.
- T0.2 Testes unitários dessas funções + `MetaTarefa`, `ItemBackup.toMap/fromMap`, `_parseEnviados` (linha truncada, linha repetida), `_ehTransitorio`. Apagar `widget_test.dart` do contador.
- T0.3 GitHub Action: `flutter analyze` + `flutter test` em push.
- T0.4 Telemetria local (A-14) no `eventos.log`/`sessoes.jsonl`.
- T0.5 Corrigir README (A-33).
- Aceite: testes verdes no CI; app idêntico pro usuário; Diagnóstico mostra velocidade por faixa de tamanho.

### F1 — Nunca perder arquivo (P0)
- T1.1 A-01: dup só com MD5 igual (calcular MD5 dos candidatos com mesmo nome|tamanho antes de marcar; em lote, com progresso "Conferindo duplicatas…").
- T1.2 A-02/A-03: `md5Checksum` na listagem; campo `v` em `enviados.jsonl` (compatível: ausência = não verificado); no apagar, verificar MD5 dos não verificados ≤ teto, com barra e cancelar.
- T1.3 A-04: confirmar hipótese em aparelho; checar permissão de localização; aviso bloqueante no apagar se negada.
- T1.4 A-05: `modifiedTime`/`createdTime` no upload (campo `mod` opcional no job).
- T1.5 A-08: medir MD5 nativo em arquivo de 2–4 GB; se aceitável, subir/remover o teto.
- T1.6 A-07: decidir com o Bruno se entra "mover pra lixeira" como opção.
- Aceite: teste manual com 2 arquivos diferentes de mesmo nome e tamanho → os dois sobem; arquivo novo no Drive mostra a data original; apagar com permissão de localização negada é barrado com explicação.
- Pergunta pro Bruno antes de começar: backups já feitos ficam com a data do upload — vale um botão "corrigir datas no Drive" (1 chamada por arquivo)?

### F2 — UX de baixo risco (ganho visível rápido)
- T2.1 A-21 menu da conta com confirmação de sair. T2.2 A-22 selecionar tudo respeita filtro. T2.3 A-24 login embutido no fluxo.
- T2.4 A-23 tela "Ajustes" (só wifi, bateria, diagnóstico, recarregar, sobre/versão); AppBar enxuta; apagar só no card/banner.
- T2.5 A-25 estados: esqueleto no carregamento, tela de permissão com botões, mensagens de erro em português claro (mapa erro→texto; exceção bruta só no diagnóstico).
- T2.6 A-26: filtro Fotos/Vídeos, `tristate` nas pastas, tocar na pasta abre a grade dela, dica de "segure pra ver" na 1ª vez, lista "Arquivos que falharam" (nome, pasta, motivo, tentar de novo).
- T2.7 A-28: tela de resultado depois de apagar ("X GB liberados", compartilhar) + histórico de backups lendo `sessoes.jsonl`; botão Fechar na vitória.
- T2.8 A-29 + A-06(a): novos grupos de sugestão e heurísticas por `relativePath`.
- T2.9 A-17 miniaturas nítidas; A-18 fonte embutida; A-30 itens baratos (`_fmt(0)`, semantics, badge 11–12 px).
- Usar o `DESIGN.md`/identidade que o Bruno tiver (skill `vibe-coding` exige fechar isso antes de construir tela nova) — perguntar.
- Aceite: roteiro manual de 12 passos (onboarding → sugestão → backup → falha simulada em modo avião → retomar → apagar → resultado) sem nenhum texto técnico na tela.

### F3 — Eficiência medida + spike do segundo plano
Só depois de F0 (precisa da telemetria).
- T3.1 Rodar 1 backup real grande e ler os números de T0.4. Decidir com dados:
  - T3.1a A-13(a) pequenos via multipart direto no Dart (pool 4–6) — só com app vivo; ou
  - T3.1b A-13(b/c) intercalar e janela por bytes.
- T3.2 A-16: motor como `ChangeNotifier` (`BackupEngine`) fora do widget; banner/card escutam; seleção incremental. É também o passo que prepara F4.
- T3.3 A-15: galeria montada pela consulta nativa (medir antes/depois; meta: lista utilizável < 1,5 s com 30 mil itens).
- T3.4 SPIKE A-10/A-11 (2 experimentos, sem compromisso de entrega):
  1. Confirmar o teto de 6 h com `adb shell am compat enable FGS_INTRODUCE_TIME_LIMITS` e uma noite de `eventos.log`.
  2. Ligar UIDT do background_downloader (`priority: 0`, permissão e serviço no manifest; conferir nome exato do serviço no README da versão instalada; considerar subir a lib pra 9.6.x) e testar: com a tela apagada há 30 min, a janela ainda consegue enfileirar tarefa nova?
  - Resultado decide F4: se UIDT + janela funciona de tela apagada → F4 fica pequena (config). Se não → F4 completa.
- Aceite: relatório curto com números antes/depois (arquivos/s em fotos, MB/s em vídeo, tempo de boot) e o veredito do spike.

### F4 — Motor que não depende do app aberto (resolve D1 na raiz)
Só se o spike mostrar necessidade. Maior fase; quebrar em sub-rodadas.
- Desenho alvo: UM job nativo de longa duração (UIDT em Android 14+, serviço em primeiro plano como fallback abaixo disso) em Kotlin que: lê a fila de `job.json`; obtém/renova token sem UI; faz upload retomável em blocos com `Content-Range` (A-12), guardando URL da sessão + offset por item; confere MD5; grava em `enviados.jsonl` (mesmo formato, o Dart continua lendo); publica progresso numa única notificação (A-20) e por canal pro Flutter. Dart vira só UI + observador.
- T4.1 Token nativo sem UI (Authorization API do Google Identity) — fazer junto a migração A-19 (google_sign_in 7.x).
- T4.2 Uploader nativo retomável em blocos + testes (corte de rede em 50%, kill do processo, sessão expirada → nova sessão).
- T4.3 Fila e persistência compartilhadas (contrato de arquivos entre Kotlin e Dart; 1 escritor por arquivo).
- T4.4 Migração: job em andamento da versão antiga é absorvido pela nova (sem re-subir, sem duplicar); manter o caminho antigo atrás de flag por 1 versão.
- T4.5 Remover background_downloader, reconciliação/órfãos/janela do Dart, e os avisos "deixe o app aberto" (A-27).
- Riscos: OEMs agressivos (Xiaomi/Samsung) matam job mesmo assim → manter pedido de isenção de bateria e retomada no boot; política da Play sobre `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` se for publicar; migração de dados.
- Aceite: 20 GB+ iniciado, app fechado pelo usuário (deslizar dos recentes), tela apagada → termina sozinho; vídeo grande com modo avião no meio continua do ponto em que parou; contagem do app bate com a do Drive.

### F5 — Publicável
- T5.1 A-35 publicar o consentimento OAuth (resolve D6). T5.2 A-34 chave de release própria + nova credencial OAuth com o SHA-1 novo + `minify`. T5.3 A-36 remover plataformas sem uso, nome/descrição do pacote. T5.4 Modo escuro. T5.5 Política de privacidade e textos de loja (se o Bruno quiser Play Store — perguntar).

## 5. Ordem recomendada e dependências

`F0 → F1 → F2 → F3 → (F4) → F5`. F2 pode andar em paralelo com F1 (arquivos diferentes depois de T0.1). F4 depende de T3.2 e do spike T3.4. Maior retorno por esforço: F1 (risco), T2.1–T2.3 (3 correções pequenas e visíveis), T3.4 (define o futuro do motor).

## 6. Perguntas abertas pro Bruno (fazer no início da próxima conversa)

1. Qual aparelho/versão do Android é o de teste, e existe `eventos.log` de um backup longo que parou sozinho? (decide A-10)
2. Objetivo final: uso próprio/família ou Play Store? (decide F5 e o peso de F4)
3. Renomear subpastas no Drive (A-06b) vale a migração, ou só melhorar as sugestões?
4. Lixeira de 30 dias como opção ao apagar (A-07)?
5. Existe identidade visual/`DESIGN.md` pra F2, ou segue o visual atual (Inter, azul #0066CC, fundo branco)?
6. Corrigir a data dos arquivos que já estão no Drive (F1)?

## 7. Não verificado nesta análise

Não rodei `flutter analyze`, testes, nem o app. Não li `ABOUT ME/`. Comportamento interno do background_downloader 9.5.5 (o que ele faz no timeout de 6 h, se reenvia do zero em retry, paralelismo real do WorkManager) foi inferido do uso no código e da documentação pública, não do fonte da lib. Limites numéricos da API do Drive não foram conferidos.

## 8. Fontes externas

- Timeout de serviço em primeiro plano (Android 15): https://developer.android.com/develop/background-work/services/fgs/timeout
- UIDT: https://developer.android.com/develop/background-work/background-tasks/uidt
- UIDT como alternativa ao dataSync (blog Android): https://android-developers.googleblog.com/2024/09/google-maps-improved-download-reliability-user-initiated-data-transfer-api.html
- background_downloader changelog (UIDT, prioridade 0): https://pub.dev/packages/background_downloader/changelog
- Protocolo de upload retomável (308 / Content-Range / expiração): https://developers.google.com/gdata/docs/resumable_upload
- google_sign_in 7.x: https://pub.dev/packages/google_sign_in/changelog
