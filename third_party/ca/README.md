# Mozilla CA bundle

Source: `bagder/ca-bundle`, commit `ab325adf04921579c89f77559fce20f964695ca9` on GitHub, fetched through `gh.xmly.dev` from `https://raw.githubusercontent.com/bagder/ca-bundle/ab325adf04921579c89f77559fce20f964695ca9/ca-bundle.crt`. It is converted from Mozilla NSS certdata (2026-09-03) and licensed MPL 2.0. `SHA256SUMS` pins the downloaded PEM data. The app installs it to its private `etc/ssl/cert.pem` for certificate validation; the device CA directories remain available as an additional trust source.
