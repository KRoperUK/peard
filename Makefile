.PHONY: server app prebuild clean

server:
	cd server && go run . serve --http=127.0.0.1:8090

app:
	cd app && npx expo start --ios

prebuild:
	cd app && npx expo prebuild --platform ios --no-install

clean:
	rm -rf server/pb_data server/peard-server
