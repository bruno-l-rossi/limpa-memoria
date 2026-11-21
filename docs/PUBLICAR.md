# Publicar o Limpa Memória

Passo a passo pra sair do modo de teste. Nada aqui é código: é configuração
no computador e no Google Cloud. Faça na ordem.

**Uso próprio (decisão de 2026-11-20):** só o passo 3 importa. Ele acaba com
o "pede pra logar de novo" e não mexe em código nem em chave. Os passos 1 e 2
são pra quando trocar a chave de assinatura (trocar a chave sem o passo 2
quebra o login). O passo 6 prepara o login novo do Google (achado A-19).

## 1. Chave de assinatura própria (uma vez, guarde pra sempre)

Hoje o APK de release é assinado com a chave de debug do computador. Perder
ou trocar a chave depois impede atualizar o app em quem já instalou.

No terminal do Mac, dentro da pasta `android/` do projeto:

    keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload

Crie `android/key.properties` (o git já ignora esse arquivo):

    storePassword=SENHA_QUE_VOCE_ESCOLHEU
    keyPassword=SENHA_QUE_VOCE_ESCOLHEU
    keyAlias=upload
    storeFile=../upload-keystore.jks

Faça backup do `upload-keystore.jks` e das senhas fora do computador
(gerenciador de senhas). O `build.gradle.kts` já usa essa chave sozinho
quando o `key.properties` existe.

## 2. Nova credencial OAuth com o SHA-1 da chave nova

O login do Google só funciona se o SHA-1 da chave estiver cadastrado.

    keytool -list -v -keystore android/upload-keystore.jks -alias upload | grep SHA1

No Google Cloud Console → APIs e serviços → Credenciais → Criar credencial →
ID do cliente OAuth → Android: pacote `com.rideblan.limpa_memoria` + o SHA-1
acima. Mantenha a credencial antiga (debug) pra continuar testando com
`flutter run`.

Se for publicar na Play Store com "Assinatura de apps do Google Play", cadastre
também o SHA-1 que a Play Console mostra em Integridade do app.

## 3. Tirar a tela de consentimento do modo de teste

Em modo de teste só os e-mails cadastrados entram, e o login expira de tempos
em tempos (a dor de "pede pra logar de novo").

Google Cloud Console → APIs e serviços → Tela de permissão OAuth → Publicar
app. O app usa só o escopo `drive.file` (acessa apenas o que ele mesmo cria),
que o Google classifica como não sensível; confira na tela se ele pede
verificação antes de publicar.

Vai precisar de: nome do app, e-mail de suporte, link da política de
privacidade (rascunho em `docs/PRIVACIDADE.md`, publique em qualquer página
pública).

## 4. Gerar o instalador

    flutter build apk --release        # APK pra instalar direto
    flutter build appbundle --release  # .aab pra Play Store

## 5. Se for pra Play Store

- Declarar o uso de `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (a Play restringe
  essa permissão; justificativa: backup longo iniciado pelo usuário).
- Declarar o serviço em primeiro plano `dataSync` e a permissão
  `RUN_USER_INITIATED_JOBS` (transferência iniciada pelo usuário).
- Formulário de segurança de dados: o app não coleta dados; os arquivos vão
  direto pro Drive do próprio usuário.

## 6. Client ID web (prepara o login novo do Google, achado A-19)

O app usa o google_sign_in 6, que o Google marcou como antigo. A versão 7
exige, no Android, um client ID do tipo **Aplicativo da Web** (não substitui o
de Android, convive com ele). Sem ele, migrar quebraria o login.

Google Cloud Console → APIs e serviços → Credenciais → Criar credencial → ID
do cliente OAuth → **Aplicativo da Web**. Nome: "Limpa Memória web". Não
precisa de URL nenhuma. Copie o ID que termina em
`.apps.googleusercontent.com` e mande pro Claude: com ele, a migração é uma
rodada curta (o motor do app fechado já usa a API nova de autorização).

