# Instalar no Android (versao PT-BR)

## Maquina nova / nunca instalou

1. Na [release latest](https://github.com/LordSangreal/gen1recomp/releases/latest), baixe `gen1recomp-0.5.9-ptbr-android.apk`.
2. Instale o APK (o Android vai pedir para permitir fontes desconhecidas).
3. Abra o app e importe sua ROM de Pokemon Crystal / Gold / Silver.
4. As proximas atualizacoes do motor chegam pelo proprio app, via WiFi, sem ADB.

## Ja tem o gen1recomp instalado

Nao precisa do APK. O app procura o release `latest` deste repositorio e baixa o payload sozinho. Se quiser instalar manualmente, baixe `gen1recomp-0.5.9.love` e coloque em:

```
/sdcard/Android/data/com.theboisclub.pokemonred/files/save/pokemon-love2d/updates/
```

O payload so entra na proxima abertura do app (a Boot troca se o carimbo for maior).

## Sobre a assinatura do APK

O APK publicado aqui e assinado com chave propria (`CN=Versao Dourada`). Para usa-lo sobre uma instalacao existente do APK oficial, **desinstale o app antes** — assinaturas diferentes nao coexistem sob o mesmo nome de pacote. Faca backup dos saves antes de desinstalar.

## Arquivos da release

| Arquivo | Para que serve |
|---|---|
| `gen1recomp-X.Y.Z-ptbr-android.apk` | Instalador Android completo, ja com o motor traduzido |
| `gen1recomp-X.Y.Z.love` | Payload do motor para o auto-update / instalacao manual |
| `sha256sums.txt` | Checksum exigido pelo auto-update do app |
