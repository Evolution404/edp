#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <Security/SecStaticCode.h>
#include <stdio.h>
#include <stdlib.h>

/*
 * SecCodeSigner is exported by Security.framework on macOS but its signer API is
 * not published in the current SDK headers. This helper is test-only. It builds
 * an explicit SecIdentity from temporary DER certificate/private-key material so
 * negative tests can create a real certificate-backed Mach-O signature without
 * importing an identity, changing trust settings, or touching the user's keychain.
 */
typedef struct __SecCodeSigner *SecCodeSignerRef;
extern const CFStringRef kSecCodeSignerIdentity;
extern const CFStringRef kSecCodeSignerIdentifier;
extern OSStatus SecCodeSignerCreate(CFDictionaryRef parameters,
                                    SecCSFlags flags,
                                    SecCodeSignerRef *signer);
extern OSStatus SecCodeSignerAddSignature(SecCodeSignerRef signer,
                                          SecStaticCodeRef code,
                                          SecCSFlags flags);

static int fail_status(const char *operation, OSStatus status) {
    fprintf(stderr, "%s failed: %d\n", operation, (int)status);
    return 1;
}

static CFDataRef read_file(const char *path) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return NULL;
    }
    long size = ftell(file);
    if (size <= 0 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    UInt8 *bytes = malloc((size_t)size);
    if (bytes == NULL) {
        fclose(file);
        return NULL;
    }
    size_t read_count = fread(bytes, 1, (size_t)size, file);
    fclose(file);
    if (read_count != (size_t)size) {
        free(bytes);
        return NULL;
    }
    return CFDataCreateWithBytesNoCopy(kCFAllocatorDefault,
                                       bytes,
                                       (CFIndex)size,
                                       kCFAllocatorMalloc);
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s <certificate-der> <private-key-der> <target> <identifier>\n", argv[0]);
        return 64;
    }

    const char *certificate_path = argv[1];
    const char *private_key_path = argv[2];
    const char *target_path = argv[3];
    const char *identifier_text = argv[4];

    CFDataRef certificate_data = read_file(certificate_path);
    if (certificate_data == NULL) {
        fprintf(stderr, "failed to read certificate DER\n");
        return 1;
    }
    SecCertificateRef certificate = SecCertificateCreateWithData(kCFAllocatorDefault,
                                                                  certificate_data);
    CFRelease(certificate_data);
    if (certificate == NULL) {
        fprintf(stderr, "SecCertificateCreateWithData failed\n");
        return 1;
    }

    CFDataRef private_key_data = read_file(private_key_path);
    if (private_key_data == NULL) {
        fprintf(stderr, "failed to read private key DER\n");
        CFRelease(certificate);
        return 1;
    }
    const void *key_attribute_keys[] = { kSecAttrKeyType, kSecAttrKeyClass };
    const void *key_attribute_values[] = { kSecAttrKeyTypeRSA, kSecAttrKeyClassPrivate };
    CFDictionaryRef key_attributes = CFDictionaryCreate(kCFAllocatorDefault,
                                                         key_attribute_keys,
                                                         key_attribute_values,
                                                         2,
                                                         &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    CFErrorRef key_error = NULL;
    SecKeyRef private_key = key_attributes == NULL
        ? NULL
        : SecKeyCreateWithData(private_key_data, key_attributes, &key_error);
    if (key_attributes != NULL) {
        CFRelease(key_attributes);
    }
    CFRelease(private_key_data);
    if (private_key == NULL) {
        if (key_error != NULL) {
            CFShow(key_error);
            CFRelease(key_error);
        }
        fprintf(stderr, "SecKeyCreateWithData failed\n");
        CFRelease(certificate);
        return 1;
    }

    SecIdentityRef identity = SecIdentityCreate(kCFAllocatorDefault, certificate, private_key);
    CFRelease(private_key);
    if (identity == NULL) {
        fprintf(stderr, "SecIdentityCreate failed\n");
        CFRelease(certificate);
        return 1;
    }

    CFStringRef target_string = CFStringCreateWithCString(kCFAllocatorDefault,
                                                           target_path,
                                                           kCFStringEncodingUTF8);
    CFURLRef target_url = target_string == NULL
        ? NULL
        : CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                        target_string,
                                        kCFURLPOSIXPathStyle,
                                        false);
    if (target_string != NULL) {
        CFRelease(target_string);
    }
    if (target_url == NULL) {
        fprintf(stderr, "failed to create target URL\n");
        CFRelease(identity);
        CFRelease(certificate);
        return 1;
    }

    SecStaticCodeRef code = NULL;
    OSStatus status = SecStaticCodeCreateWithPath(target_url, kSecCSDefaultFlags, &code);
    CFRelease(target_url);
    if (status != errSecSuccess || code == NULL) {
        CFRelease(identity);
        CFRelease(certificate);
        return fail_status("SecStaticCodeCreateWithPath", status);
    }

    CFStringRef identifier = CFStringCreateWithCString(kCFAllocatorDefault,
                                                        identifier_text,
                                                        kCFStringEncodingUTF8);
    if (identifier == NULL) {
        fprintf(stderr, "failed to create identifier\n");
        CFRelease(code);
        CFRelease(identity);
        CFRelease(certificate);
        return 1;
    }

    const void *signer_keys[] = { kSecCodeSignerIdentity, kSecCodeSignerIdentifier };
    const void *signer_values[] = { identity, identifier };
    CFDictionaryRef parameters = CFDictionaryCreate(kCFAllocatorDefault,
                                                     signer_keys,
                                                     signer_values,
                                                     2,
                                                     &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
    CFRelease(identifier);
    if (parameters == NULL) {
        fprintf(stderr, "failed to create signer parameters\n");
        CFRelease(code);
        CFRelease(identity);
        CFRelease(certificate);
        return 1;
    }

    SecCodeSignerRef signer = NULL;
    status = SecCodeSignerCreate(parameters, kSecCSDefaultFlags, &signer);
    CFRelease(parameters);
    if (status != errSecSuccess || signer == NULL) {
        CFRelease(code);
        CFRelease(identity);
        CFRelease(certificate);
        return fail_status("SecCodeSignerCreate", status);
    }

    status = SecCodeSignerAddSignature(signer, code, kSecCSDefaultFlags);

    CFRelease(signer);
    CFRelease(code);
    CFRelease(identity);
    CFRelease(certificate);

    if (status != errSecSuccess) {
        return fail_status("SecCodeSignerAddSignature", status);
    }

    puts("RESULT=EXPLICIT_IDENTITY_SIGN_OK");
    return 0;
}
