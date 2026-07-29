.PHONY: build test app run clean

build:
	swift build

test:
	swift test

app:
	./Scripts/build-app.sh release

run:
	swift run AvatarCompanion

clean:
	swift package clean
	rm -rf build
