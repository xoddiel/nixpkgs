{
  stdenv,
  buildGoModule,
  callPackage,
  fetchFromGitHub,
  fetchurl,
  lib,

  buf,
  cacert,
  grpc-gateway,
  protoc-gen-go,
  protoc-gen-go-grpc,
  protoc-gen-validate,
  sass,
  statik,
  yq-go,
}:

let
  version = "2.71.7";
  zitadelRepo = fetchFromGitHub {
    owner = "zitadel";
    repo = "zitadel";
    rev = "v${version}";
    hash = "sha256-0ZOiwJ/ehDBkbd7iTTyVJzLj6Etph5/oxrDrck30ZL8=";
  };
  goModulesHash = "sha256-iZCjHSpQ7Gy41Dd4svRLbyEh1N8VE8U0uCOlN9rfJQU=";

  buildZitadelProtocGen =
    name:
    buildGoModule {
      pname = "protoc-gen-${name}";
      inherit version;

      src = zitadelRepo;

      proxyVendor = true;
      vendorHash = goModulesHash;

      buildPhase = ''
        go install internal/protoc/protoc-gen-${name}/main.go
      '';

      postInstall = ''
        mv $out/bin/main $out/bin/protoc-gen-${name}
      '';
    };

  protoc-gen-authoption = buildZitadelProtocGen "authoption";
  protoc-gen-zitadel = buildZitadelProtocGen "zitadel";

  fetchProtobufDep =
    {
      remote ? "buf.build",
      owner,
      repo,
      rev,
      hash,
      imports ? false,
    }:
    fetchurl {
      pname = "${repo}-buf-dep";
      version = rev;

      url = "https://${remote}/${owner}/${repo}/archive/${rev}.tar.gz${if imports then "?imports=true" else ""}";

      inherit hash;
      recursiveHash = true;

      downloadToTemp = true;

      postFetch = ''
        mkdir $out
        tar -xvf "$downloadedFile" -C "$out"
        echo 'version: v1' > "$out/buf.lock"
      '';
    };

  protobufDeps = {
    protoc-gen-validate = {
      owner = "envoyproxy";
      repo = "protoc-gen-validate";
      rev = "6607b10f00ed4a3d98f906807131c44a";
      hash = "sha256-8CN3p7wIRPTzLJoILnvjash6qFOdixUN7Wia5pdc/A8=";
    };

    googleapis = {
      owner = "googleapis";
      repo = "googleapis";
      rev = "75b4300737fb4efca0831636be94e517";
      hash = "sha256-TimZ6UdByjoKXb4BARydkzEn1Niy3IvXk4B8D/J1L1M=";
    };

    grpc-gateway = {
      owner = "grpc-ecosystem";
      repo = "grpc-gateway";
      rev = "a1ecdc58eccd49aa8bea2a7a9022dc27";
      hash = "sha256-J77NEgrawkNy3h8xVni/ah2IKdQVBf9bdxJ5DGPqWww=";
    };
  };

  # Buf downloads dependencies from an external repo - there doesn't seem to
  # really be any good way around it. We'll use a fixed-output derivation so it
  # can download what it needs, and output the relevant generated code for use
  # during the main build.
  generateProtobufCode =
    {
      pname,
      version,
      nativeBuildInputs ? [ ],
      bufArgs ? "",
      workDir ? ".",
      outputPath,
    }:
    stdenv.mkDerivation {
      pname = "${pname}-buf-generated";
      inherit version;

      src = zitadelRepo;
      patches = [ ./console-use-local-protobuf-plugins.patch ];

      nativeBuildInputs = nativeBuildInputs ++ [
        buf
        cacert
        yq-go
      ];

      # We remove remote dependencies and manually attach our fetched dependencies
      # to the project as directories. Sadly, buf demands relative paths, so we first
      # have to create a symbolic link for each dependency.
      buildPhase = ''
        yq --inplace '.deps = []' proto/buf.yaml
        yq --inplace '.deps = []' proto/buf.lock
        mkdir buf-vendor

        ${lib.concatLines (
          lib.flip lib.mapAttrsToList protobufDeps (
            name: dep: ''
              ln -s "${fetchProtobufDep dep}" "buf-vendor/${name}"
              yq --inplace '.directories += ["buf-vendor/${name}"]' buf.work.yaml
            ''
          )
        )}

        cd ${workDir}
        HOME=$TMPDIR buf generate --debug ${bufArgs}
      '';

      installPhase = ''
        cp -r ${outputPath} $out
      '';
    };

  protobufGenerated = generateProtobufCode {
    pname = "zitadel";
    inherit version;
    nativeBuildInputs = [
      grpc-gateway
      protoc-gen-authoption
      protoc-gen-go
      protoc-gen-go-grpc
      protoc-gen-validate
      protoc-gen-zitadel
    ];
    outputPath = ".artifacts";
  };
in
buildGoModule rec {
  pname = "zitadel";
  inherit version;

  src = zitadelRepo;

  nativeBuildInputs = [
    sass
    statik
  ];

  proxyVendor = true;
  vendorHash = goModulesHash;
  ldflags = [ "-X 'github.com/zitadel/zitadel/cmd/build.version=${version}'" ];

  # Adapted from Makefile in repo, with dependency fetching and protobuf codegen
  # bits removed
  preBuild = ''
    mkdir -p pkg/grpc
    cp -r ${protobufGenerated}/grpc/github.com/zitadel/zitadel/pkg/grpc/* pkg/grpc
    mkdir -p openapi/v2/zitadel
    cp -r ${protobufGenerated}/grpc/zitadel/ openapi/v2/zitadel

    go generate internal/api/ui/login/static/resources/generate.go
    go generate internal/api/ui/login/statik/generate.go
    go generate internal/notification/statik/generate.go
    go generate internal/statik/generate.go

    mkdir -p docs/apis/assets
    go run internal/api/assets/generator/asset_generator.go -directory=internal/api/assets/generator/ -assets=docs/apis/assets/assets.md

    cp -r ${passthru.console}/* internal/api/ui/console/static
  '';

  doCheck = false;

  installPhase = ''
    mkdir -p $out/bin
    install -Dm755 $GOPATH/bin/zitadel $out/bin/
  '';

  passthru = {
    console = callPackage (import ./console.nix {
      inherit generateProtobufCode version zitadelRepo;
    }) { };
  };

  meta = {
    description = "Identity and access management platform";
    homepage = "https://zitadel.com/";
    downloadPage = "https://github.com/zitadel/zitadel/releases";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
    maintainers = [ lib.maintainers.nrabulinski ];
  };
}
