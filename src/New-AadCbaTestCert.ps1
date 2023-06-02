[CmdletBinding()]
param (
    [Parameter()]
    [String]
    $CASubj = '/DC=COM/DC=ONMICROSOFT/DC=<YOURTENANTNAME>/CN=<YOURCANAME>',

    [Parameter()]
    [String]
    $UserSubj = '/C=US/O=<YOURORGNAME>/CN=<USERDISPLAYNAME>',

    [Parameter()]
    [String]
    $UserPN = '<useremail@domain.name>',

    [Parameter()]
    [ValidateScript({ $_ -ge 1 },
        ErrorMessage = 'CAValidityDays must be at least 1. Entered value was {0}.')]
    [int]
    $CAValidityDays = 720,

    [Parameter()]
    [ValidateScript({ $_ -le $CAValidityDays -and $_ -ge 1 },
        ErrorMessage = 'UserValidityDays must be less than or equal to the CAValidityDays parameter and at least 1. Entered value was {0}.')]
    [int]
    $UserValidityDays = 365,

    [Parameter()]
    [ValidateRange(1024, 4096)]
    [int]
    $CAKeyLength = 4096,

    [Parameter()]
    [ValidateRange(512, 2048)]
    [ValidateScript({ $_ -le $CAKeyLength },
        ErrorMessage = 'UserKeyLength must be less or equal to the CAKeyLength parameter. Entered value was {0}.')]
    [int]
    $UserKeyLength = 2048

)

# Path to OpenSSL if GIT for Windows is installed. Otherwise the user needs to find another OpenSSL path
if ($env:path -notcontains 'git\usr\bin')
{
    if (Test-Path 'C:\Program Files\Git\usr\bin')
    {
        $env:path += ';C:\Program Files\Git\usr\bin'
    }
    elseif (Test-Path 'C:\Program Files (x86)\Git\usr\bin')
    {
        $env:path += ';C:\Program Files(x86)\Git\usr\bin'

    }
}

#Make sure OpenSSL can run.
try
{
    openssl version | Out-Null
}
catch
{
    Write-Error 'Could not find OpenSSL. Install OpenSSL and/or add it to the system path.'
}

# Create a root CA certificate
openssl req -x509 -days $CAValidityDays -newkey rsa:$CAKeyLength -keyout capriv.pem -out cacert.pem -subj $CASubj
# Convert PEM to CER so AAD will accept it.
openssl x509 -in cacert.pem -out cacert.cer -outform DER
# Create a certificate request. Note that Yubkikey only supports 2048-bit RSA keys
openssl req -new -newkey rsa:$UserKeyLength -keyout userkey.pem -out userreq.pem -subj $UserSubj
# Generate a config file to populate extensions in the certificate. Set-Content is wonky to create Unix-style line endings
$SAN = @("subjectAltName=otherName:1.3.6.1.4.1.311.20.2.3;UTF8:$UserPN",
    'keyUsage=digitalSignature, Key Encipherment',
    'extendedKeyUsage=1.3.6.1.4.1.311.20.2.2,1.3.6.1.5.5.7.3.2')
Set-Content -Path .\cert.cfg -NoNewline -Encoding utf8 -Value (($SAN -join "`n") + "`n")
# Process the certificate request
openssl x509 -req -in userreq.pem -days $UserValidityDays -CA cacert.pem -CAkey capriv.pem -CAcreateserial -out user.pem -extfile cert.cfg
#convert PEM to CER so the cert can be opened and examined in Windows
openssl x509 -in user.pem -out user.cer -outform DER
# Merge public and private keys in PFX for import to Yubikey
openssl pkcs12 -inkey userkey.pem -in user.pem -export -out user.pfx
