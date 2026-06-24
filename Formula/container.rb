class Container < Formula
  desc "Create and run Linux containers using lightweight virtual machines"
  homepage "https://apple.github.io/container/documentation/"
  license "Apache-2.0"
  head "https://github.com/stephenlclarke/container.git", branch: "main"

  depends_on xcode: ["26.0", :build]
  depends_on arch: :arm64
  depends_on macos: :sequoia

  def install
    ENV["GIT_COMMIT"] = Utils.git_head

    system "swift", "build", "--disable-sandbox", "--configuration", "release"

    release_dir = buildpath/".build/release"

    bin.install release_dir/"container"
    bin.install release_dir/"container-apiserver"
    libexec.install "scripts/ensure-container-stopped.sh"

    codesign "--identifier=com.apple.container.cli", bin/"container"
    codesign "--identifier=com.apple.container.apiserver", bin/"container-apiserver"

    plugins = {
      "container-core-images"   => {
        source: "Sources/Plugins/CoreImages",
      },
      "container-network-vmnet" => {
        source:       "Sources/Plugins/NetworkVmnet",
        entitlements: "signing/container-network-vmnet.entitlements",
      },
      "container-runtime-linux" => {
        source:       "Sources/Plugins/RuntimeLinux",
        entitlements: "signing/container-runtime-linux.entitlements",
      },
      "machine-apiserver"       => {
        source:    "Sources/Plugins/MachineAPIServer",
        resources: ["Resources/init", "Resources/create-user.sh"],
      },
    }

    plugins.each do |name, config|
      plugin_dir = libexec/"container/plugins"/name
      plugin_dir.install "#{config[:source]}/config.toml"
      (plugin_dir/"bin").install release_dir/name
      codesign_args = ["--identifier=com.apple.container.#{name}", plugin_dir/"bin"/name]
      codesign_args.unshift "--entitlements", config[:entitlements] if config[:entitlements]
      codesign(*codesign_args)
      next unless config[:resources]

      (plugin_dir/"resources").install(*config[:resources].map { |resource| "#{config[:source]}/#{resource}" })
    end

    generate_completions_from_executable bin/"container", "--generate-completion-script"

    bin.env_script_all_files libexec/"bin", CONTAINER_INSTALL_ROOT: opt_prefix
  end

  def codesign(*args)
    system "/usr/bin/codesign", "-f", "-s", "-", *args
  end

  def post_install
    system libexec/"ensure-container-stopped.sh", "-a"
  end

  service do
    run [opt_bin/"container", "system", "start"]
    keep_alive true
    working_dir var
    log_path var/"log/container.log"
    error_log_path var/"log/container.log"
  end

  test do
    assert_match "container CLI version", shell_output("#{bin}/container --version")
    assert_match(/Error: (?:interrupted: ")?internalError: "failed to list containers"/,
                 shell_output("#{bin}/container list 2>&1", 1))
  end
end
