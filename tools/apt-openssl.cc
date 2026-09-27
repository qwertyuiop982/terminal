// OpenSSL transport for upstream APT's HTTP method on Android bionic.
// Certificate and hostname verification are mandatory for every TLS connection.
#include <apt-pkg/configuration.h>
#include <apt-pkg/error.h>
#include <apt-pkg/fileutl.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509_vfy.h>

#include <algorithm>
#include <cerrno>
#include <climits>
#include <memory>
#include <string>
#include <arpa/inet.h>

#include "aptmethod.h"
#include "connect.h"

namespace {
struct OpenSslFd final : MethodFd {
   std::unique_ptr<MethodFd> underlying;
   SSL_CTX *context = nullptr;
   SSL *session = nullptr;
   unsigned long timeout = 0;

   ~OpenSslFd() override { Close(); }
   int Fd() override { return underlying ? underlying->Fd() : -1; }

   ssize_t transfer(void *buffer, size_t count, bool writing) {
      if (!session) { errno = EBADF; return -1; }
      if (count == 0) return 0;
      int const size = static_cast<int>(std::min(count, static_cast<size_t>(INT_MAX)));
      int const result = writing ? SSL_write(session, buffer, size) : SSL_read(session, buffer, size);
      if (result > 0) return result;
      switch (SSL_get_error(session, result)) {
      case SSL_ERROR_ZERO_RETURN: return 0;
      case SSL_ERROR_WANT_READ:
      case SSL_ERROR_WANT_WRITE: errno = EAGAIN; return -1;
      default: errno = EIO; return -1;
      }
   }
   ssize_t Read(void *buffer, size_t count) override { return transfer(buffer, count, false); }
   ssize_t Write(void *buffer, size_t count) override { return transfer(buffer, count, true); }
   bool HasPending() override { return session && SSL_pending(session) > 0; }
   int Close() override {
      if (session) { SSL_free(session); session = nullptr; }
      if (context) { SSL_CTX_free(context); context = nullptr; }
      return underlying ? underlying->Close() : 0;
   }
};

ResultState tlsError(char const *message) {
   unsigned long const code = ERR_get_error();
   _error->Error("TLS: %s: %s", message, code ? ERR_error_string(code, nullptr) : "verification failed");
   return ResultState::FATAL_ERROR;
}
} // namespace

ResultState UnwrapTLS(std::string const &host, std::unique_ptr<MethodFd> &fd,
                      unsigned long timeout, aptMethod *owner,
                      aptConfigWrapperForMethods const *options) {
   if (!_config->FindB("Acquire::AllowTLS", true) ||
       !options->ConfigFindB("Verify-Peer", true) ||
       !options->ConfigFindB("Verify-Host", true)) {
      _error->Error("TLS certificate and hostname verification must remain enabled");
      return ResultState::FATAL_ERROR;
   }
   if (!options->ConfigFind("IssuerCert", "").empty() ||
       !options->ConfigFind("SslForceVersion", "").empty() ||
       !options->ConfigFind("CrlFile", "").empty()) {
      _error->Error("Unsupported TLS option on Android; refusing to ignore it");
      return ResultState::FATAL_ERROR;
   }
   if (dynamic_cast<OpenSslFd *>(fd.get()) || fd->HasPending()) {
      _error->Error("Nested or buffered TLS proxy connections are not supported on Android");
      return ResultState::FATAL_ERROR;
   }

   auto tls = std::make_unique<OpenSslFd>();
   tls->timeout = timeout;
   tls->context = SSL_CTX_new(TLS_client_method());
   if (!tls->context || SSL_CTX_set_min_proto_version(tls->context, TLS1_2_VERSION) != 1)
      return tlsError("cannot initialize TLS client");
   SSL_CTX_set_verify(tls->context, SSL_VERIFY_PEER, nullptr);
   auto const ca = options->ConfigFind("CaInfo", "");
   if (ca.empty()) {
      if (SSL_CTX_set_default_verify_paths(tls->context) != 1)
         return tlsError("cannot load device CA certificates");
   } else if (SSL_CTX_load_verify_locations(tls->context, ca.c_str(), nullptr) != 1)
      return tlsError("cannot load CaInfo");

   auto const cert = options->ConfigFind("SslCert", "");
   auto const key = options->ConfigFind("SslKey", "");
   if (cert.empty() != key.empty()) {
      _error->Error("Both SslCert and SslKey must be set for TLS client authentication");
      return ResultState::FATAL_ERROR;
   }
   if (!cert.empty() &&
       (SSL_CTX_use_certificate_file(tls->context, cert.c_str(), SSL_FILETYPE_PEM) != 1 ||
        SSL_CTX_use_PrivateKey_file(tls->context, key.c_str(), SSL_FILETYPE_PEM) != 1 ||
        SSL_CTX_check_private_key(tls->context) != 1))
      return tlsError("invalid client certificate or key");

   tls->session = SSL_new(tls->context);
   if (!tls->session || SSL_set_fd(tls->session, fd->Fd()) != 1)
      return tlsError("cannot attach TLS socket");
   struct in_addr ipv4;
   struct in6_addr ipv6;
   bool const isIp = inet_pton(AF_INET, host.c_str(), &ipv4) == 1 ||
                     inet_pton(AF_INET6, host.c_str(), &ipv6) == 1;
   if (isIp) {
      if (X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(tls->session), host.c_str()) != 1)
         return tlsError("invalid IP address for certificate verification");
   } else if (SSL_set1_host(tls->session, host.c_str()) != 1 ||
              SSL_set_tlsext_host_name(tls->session, host.c_str()) != 1)
      return tlsError("invalid TLS hostname");

   tls->underlying = std::move(fd);
   fd = std::move(tls);
   auto *connected = static_cast<OpenSslFd *>(fd.get());
   while (true) {
      int const result = SSL_connect(connected->session);
      if (result == 1) break;
      int const code = SSL_get_error(connected->session, result);
      if (code != SSL_ERROR_WANT_READ && code != SSL_ERROR_WANT_WRITE) {
         auto const verify = SSL_get_verify_result(connected->session);
         _error->Error("TLS handshake failed for %s: %s", host.c_str(),
                       verify == X509_V_OK ? "connection error" : X509_verify_cert_error_string(verify));
         return ResultState::FATAL_ERROR;
      }
      if (!WaitFd(fd->Fd(), code == SSL_ERROR_WANT_WRITE, timeout)) {
         _error->Error("TLS handshake timed out for %s", host.c_str());
         return ResultState::TRANSIENT_ERROR;
      }
   }
   if (SSL_get_verify_result(connected->session) != X509_V_OK) {
      _error->Error("TLS certificate verification failed for %s", host.c_str());
      return ResultState::FATAL_ERROR;
   }
   return ResultState::SUCCESSFUL;
}