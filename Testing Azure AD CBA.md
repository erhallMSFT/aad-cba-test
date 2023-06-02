# Testing Azure AD CBA
Certificate Based Authentication is an Azure feature to allow users to sign-in with a smartcard. Testing this feature in a test tenant can be difficult if you don't have a public key infrastructure already established. This document walks through how to quickly set up some test certificates to enable testing the feature.

>**This example is for test purposes only. Certificates created following this process are not secure and should never be used for production authentication.**

## Prerequisites
1. A test [Azure AD tenant](https://learn.microsoft.com/en-us/azure/active-directory/fundamentals/active-directory-access-create-new-tenant) where you can elevate to the Global Administrator role.
1. An installation of OpenSSL. This doc assumes that you're working in Windows 11, and that you have [Git for Windows](https://git-scm.com/downloads) installed on your PC, since Git includes OpenSSL in the install package.
1. A smartcard that you can add a certificate to. This doc assumes you're using a [Yubikey](https://www.yubico.com/products). You will need to know the [Management Key](https://docs.yubico.com/yesdk/users-manual/application-piv/pin-puk-mgmt-key.html) for your Yubikey's PIV app - it's set to a default value if you're using your own Yubikey; you probably won't be able to use one provided by your workplace if they have configured the Management Key. You will also need the PIN associated with the PIV app (note that different PINs may be set for PIV and FIDO2 applications).
4. The [Yubikey Manager](https://www.yubico.com/support/download/yubikey-manager/) application installed if you're using a Yubikey.

## Creating the signed key
### Create a Certification Authority certificate
In a PKI, the certification authority (CA) is a system trusted to issue certificates. The root CA is at the top of the trust hierarchy and uses a self-signed certificate.

Run the commands below in PowerShell, changing the first value in brackets to match the desired subject name for the CA certificate. The first line creates a variable to hold the certificate subject nname. The second line creates a self-signed certificate with separate PEM files for the private key (`capriv.pem`) and the public key (`cacert.pem`). The certificate will have a 2 year (720 days) validity period and uses a 4096-bit RSA key. You will be prompted to enter a password to protect the private key.

```powershell
$CASubj = "/DC=COM/DC=ONMICROSOFT/DC=<YOURTENANTNAME>/CN=<YOURCANAME>"
openssl req -x509 -days 720 -newkey rsa:4096 -keyout capriv.pem -out cacert.pem -subj $CASubj
```

After creating the certificate, convert it from PEM to DER format so that the resulting file (`cacert.cer`) can be uploaded to Azure AD.

```
openssl x509 -in cacert.pem -out cacert.cer -outform DER
```

### Issue a user certificate
Once the CA certificate is created, use it to issue a certificate for the user. Azure AD has a number of options for mapping a certificate to a user. For this doc, we will map to the user by including the Principal Name corresponding to the user's userPrincipalName in the certificate SubjectAlternateName field.

First define PowerShell variables for the certificate subject name and userPrincipalName. The subject name can be anything, but typically identifies the certificate hierarchy and the user's displayName. The userPrincipalName is the value the user uses to sign-in to Azure AD. It usually (but not always) is the same as the user's email address. Change the values in brackets to match the user of the certificate.

``` powershell
$UserSubj = "/C=US/O=<YOURORGNAME>/CN=<USERDISPLAYNAME>"`
$UserPN = "<useremail@domain.name>"
```

Next create the certificate request. This request uses a 2048-bit RSA key, which is the maximum size that Yubikey supports. The request command creates a private key (`userkey.pem`) and a request file (`userreq.pem`) to submit to the CA for signing.

```
openssl req -new -newkey rsa:2048 -keyout userkey.pem -out userreq.pem -subj $UserSubj
```

### Issue the certificate
Issuing a certificate simply consists of the CA signing the certificate request using its private key. In addition, the CA can apply extensions to the certificate. With a production CA, the extensions are usually added automatically based on a certificate template. Here we will define and apply them manually.

First, create a configuration file to hold the required extensions. These extensions specify the values for the subject alternate name field, and the usage and extended usage attributes of the certificate. The usage attributes help indicate to Azure AD that the certificate is intended for authenticating a user. The `Set-Content` command is used to create the file to ensure that it is in the Unix format that OpenSSL expects.

```powershell
$SAN = @(
    "subjectAltName=otherName:1.3.6.1.4.1.311.20.2.3;UTF8:$UserPN"
    "keyUsage=digitalSignature, Key Encipherment"
    "extendedKeyUsage=1.3.6.1.4.1.311.20.2.2,1.3.6.1.5.5.7.3.2"
)
Set-Content -Path .\cert.cfg -NoNewline -Encoding utf8 -Value (($SAN -join "`n") + "`n")
```

Sign the certificate using the CA certificate and private key. The command will prompt for the password that you specified when creating the CA private key.

```
openssl x509 -req -in userreq.pem -days 365 -CA cacert.pem -CAkey capriv.pem -CAcreateserial -out user.pem -extfile cert.cfg
```

After signing the certificate, you can (optionally) conver the resulting PEM file to DER format so that you can open it in Windows to ensure all fields were created correctly.

```
openssl x509 -in user.pem -out user.cer -outform DER
```

Finally, merge the signed certificate with the private key into a PFX file that can be uploaded to the Yubikey. You will be prompted first for the password you set when creating the certificate request, then for a new password to protect the PFX.
```
openssl pkcs12 -inkey userkey.pem -in user.pem -export -out user.pfx
```

## Configure the YubiKey
Launch the Yubikey Manager application and attach a Yubikey to the PC. In YubiManager, select PIV from the application menu.

![YubiKey Manager application window on the home screen, with a key attached and the Applications menu opened to select the PIV application.](/assets/YubiMgr1.png)

On the certificates screen, select the Authentication tab and click the **Import** button. The Windows file picker will open. Select the PFX file you created earlier and click **Import**. You will be prompted first for the PFX file password and then for the management key associated with your Yubikey. After providing both keys the certificate will be listed in one of the Authentication slots.

![PIV application opened in YubiKey Manager, showing a user certificate installed in Authentication slot 9A.](/assets/YubiMgr2.png)

## Configure Azure AD
[Detailed documentation](https://learn.microsoft.com/en-us/azure/active-directory/authentication/how-to-certificate-based-authentication) is available on the Microsoft Learn site for enabling CBA. The steps below are a summary of the minimum steps to enable a user to authenticate **for testing purposes only**. Additional configuration is needed to ensure that certificate authentication is performed securely.

### Configure Certificate Authority
Open the Entra portal and navigate to the [Certificate authorities](https://entra.microsoft.com/#view/Microsoft_AAD_IAM/SecurityMenuBlade/~/CertificateAuthorities) menu in the Security blade. Click upload and select the `cacert.cer` file you created earlier. Leave the root CA button set to **Yes**. For testing purposes, leave the certificate revocation fields empty.

### Configure certificate authentication methods
In the Entra portal open the [Authentication methods blade](https://entra.microsoft.com/#view/Microsoft_AAD_IAM/AuthenticationMethodsMenuBlade/~/AdminAuthMethods/fromNav/Identity). In the Policies section, select **Certificate-based authentication**.

![Entra Portal website, opened to the Authentication Policies page.](/assets/Entra1.png)

On the Enable and Target screen, turn on the **Enable** slider. You can decide whether to target **All users** or pick a subset of groups. Click **Save**, then change to the Configure screen. Select **Multi-factor authentication** for the Protection Level. In the Username binding section, select **userPrincipalName** as the User attribute for the PrincipalName certificate field. Click the **Save** button and you are ready to test the configuration.

## Test Certificate Based Authentication
Make sure the Yubikey containing the certificate is attached to the PC. Open an InPrivate browser session in Edge (or an Incognito session in Chrome). Browse to a site that requires authentication, such as the [Azure Portal](https://portal.azure.com) or the [Microsoft365 portal](https://portal.office.com). Enter the user name and click Next. If prompted for an authentication type, choose **Use a certificate or smart card**. If the user has signed-in previously, Azure AD might default to a different sign-in methond. In that case, cancel the sign-in and choose **Other ways to sign in**, then pick the smart card option. You will be prompted first to select a certificate, then to provide the smart card PIN for the Yubikey.
>Note: If certificate authentication fails for any reason, close the browser window (not just the tab) and start over with a new InPrivate/Incognito session.