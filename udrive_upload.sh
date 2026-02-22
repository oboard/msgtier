rm -f msgtier-linux-x64.zip
aria2c https://nightly.link/oboard/msgtier/workflows/build.yaml/main/msgtier-linux-x64.zip -o msgtier-linux-x64.zip
udrive upload msgtier-linux-x64.zip
rm -f msgtier-linux-x64.zip