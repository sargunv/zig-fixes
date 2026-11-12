// Only the fake SDK's libSystem exports this, so linking succeeds only if
// the compiler took libSystem from the sysroot.
int fake_sdk_marker(void);

int main(void) {
    return fake_sdk_marker();
}
