SCHEME=Signal
PODS=Pods
BACKUP_TESTS=SignalServiceKit/tests/MessageBackup/Signal-Message-Backup-Tests

.PHONY: dependencies
dependencies: pod-setup backup-tests-setup

.PHONY: pod-setup
pod-setup:
	./Scripts/setup_private_pods
	git submodule update --init --progress ${PODS}
	$(MAKE) fetch-ringrtc
	pod install --deployment

.PHONY: backup-tests-setup
backup-tests-setup:
	git submodule update --init --progress ${BACKUP_TESTS}

.PHONY: fetch-ringrtc
fetch-ringrtc:
	$(CURDIR)/Pods/SignalRingRTC/bin/set-up-for-cocoapods
