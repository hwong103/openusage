// Grants OpenUsage read access to a login-keychain item owned by another app.
//
// macOS binds Keychain ACL entries to a code identity. An ad-hoc-signed binary has a bare-cdhash
// designated requirement that changes on every rebuild, so it can never be a durable ACL entry and
// its reads are denied. OpenUsage is signed with a stable local identity instead, which this tool
// registers as a trusted application alongside the item's existing owner.
//
// Usage: ou-grant <keychain-service> <keychain-account> <app-path> [other-trusted-app ...]
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <Security/SecKeychainItem.h>
#import <Security/SecTrustedApplication.h>
#import <Security/SecAccess.h>

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 4) {
      fprintf(stderr,
              "usage: ou-grant <keychain-service> <keychain-account> <app-path> [other-trusted-app ...]\n");
      return 2;
    }
    const char *service = argv[1];
    const char *account = argv[2];

    SecKeychainItemRef item = NULL;
    OSStatus found = SecKeychainFindGenericPassword(NULL,
        (UInt32)strlen(service), service,
        (UInt32)strlen(account), account, NULL, NULL, &item);
    printf("find_status=%d service=%s\n", (int)found, service);
    // A missing item is a normal state (e.g. Claude Desktop never signed in), not a failure.
    if (found == errSecItemNotFound) { printf("item_absent=true\n"); return 0; }
    if (found != errSecSuccess) return 1;

    int total = argc - 3;
    SecTrustedApplicationRef *apps = calloc(total, sizeof(SecTrustedApplicationRef));
    int built = 0;
    for (int i = 3; i < argc; i++) {
      SecTrustedApplicationRef app = NULL;
      OSStatus made = SecTrustedApplicationCreateFromPath(argv[i], &app);
      if (made == errSecSuccess) {
        apps[built++] = app;
        printf("trusted_app[%d]=%s\n", i - 3, argv[i]);
      } else {
        fprintf(stderr, "could not trust %s (status=%d)\n", argv[i], (int)made);
      }
    }
    if (built == 0) { free(apps); CFRelease(item); return 1; }

    CFArrayRef list = CFArrayCreate(NULL, (const void **)apps, built, &kCFTypeArrayCallBacks);
    SecAccessRef access = NULL;
    OSStatus created = SecAccessCreate(
        CFStringCreateWithCString(NULL, "OpenUsage local access", kCFStringEncodingUTF8),
        list, &access);
    printf("access_create_status=%d\n", (int)created);
    if (created != errSecSuccess) return 1;

    OSStatus set = SecKeychainItemSetAccess(item, access);
    printf("set_access_status=%d\n", (int)set);

    CFRelease(access); CFRelease(list);
    for (int i = 0; i < built; i++) CFRelease(apps[i]);
    free(apps); CFRelease(item);
    return set == errSecSuccess ? 0 : 1;
  }
}
