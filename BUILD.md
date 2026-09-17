# Compilação

Este é um projeto iOS baseado em SwiftUI e Xcode. A compilação precisa ser executada em macOS com Xcode, pois o SDK da Apple e o `xcodebuild` não estão disponíveis em Linux.

O workflow [`.github/workflows/ios-build.yml`](.github/workflows/ios-build.yml) compila o esquema compartilhado `3105` em modo `Release`, sem assinatura, e publica como artefatos:

- `3105-unsigned.ipa`
- `3105-unsigned.app.zip`
- `xcodebuild.log`

Para iniciar manualmente, abra a aba **Actions**, selecione **iOS Build** e clique em **Run workflow**. Os artefatos sem assinatura não são instaláveis em um dispositivo; a assinatura e o provisioning profile devem ser fornecidos em uma etapa de distribuição autorizada.
