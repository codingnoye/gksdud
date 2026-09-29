// vhid-keys: owns one Karabiner DriverKit virtual keyboard (root only) and presses keys sent as text lines
// over a Unix socket that only the invoking sudo user can open. Ctrl+C or "quit" removes the keyboard.
//
//   sudo build/vhid-keys build/vhid.sock
//
// Commands, one per line: "down <key>", "up <key>", "release", "ping", "quit". Each gets "ok" or "error <why>".
// The keyboard uses the vendor/product of Karabiner-Elements' own virtual keyboard, so gksdud treats it as that
// keyboard (same saved preference and mapping). It is destroyed when this helper exits.

#include <atomic>
#include <csignal>
#include <cstdio>
#include <iostream>
#include <map>
#include <pqrs/karabiner/driverkit/virtual_hid_device_driver.hpp>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace hid_report = pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report;

namespace {
std::atomic<bool> ready(false);
std::atomic<int> listener(-1);

std::optional<hid_report::modifier> modifier_named(const std::string& name) {
  static const std::map<std::string, hid_report::modifier> modifiers = {
      {"lctrl", hid_report::modifier::left_control}, {"lshift", hid_report::modifier::left_shift},
      {"lopt", hid_report::modifier::left_option}, {"lcmd", hid_report::modifier::left_command},
      {"rctrl", hid_report::modifier::right_control}, {"rshift", hid_report::modifier::right_shift},
      {"ropt", hid_report::modifier::right_option}, {"rcmd", hid_report::modifier::right_command},
  };
  if (auto it = modifiers.find(name); it != modifiers.end()) return it->second;
  return std::nullopt;
}

// HID keyboard page usages.
std::optional<uint16_t> usage_named(const std::string& name) {
  static const std::map<std::string, uint16_t> keys = {
      {"return", 0x28}, {"esc", 0x29}, {"delete", 0x2a}, {"tab", 0x2b}, {"space", 0x2c}, {"caps", 0x39},
      {"f13", 0x68}, {"f14", 0x69}, {"f15", 0x6a}, {"f16", 0x6b}, {"f17", 0x6c}, {"f18", 0x6d}, {"f19", 0x6e}, {"f20", 0x6f},
  };
  if (auto it = keys.find(name); it != keys.end()) return it->second;
  if (name.size() == 1 && name[0] >= 'a' && name[0] <= 'z') return static_cast<uint16_t>(0x04 + name[0] - 'a');
  return std::nullopt;
}
} // namespace

int main(int argc, const char* argv[]) {
  if (argc != 2 || geteuid() != 0) {
    std::cerr << "usage: sudo " << argv[0] << " <socket path>" << std::endl;
    return 2;
  }
  const char* sudo_uid = getenv("SUDO_UID");
  const char* sudo_gid = getenv("SUDO_GID");
  if (!sudo_uid || !sudo_gid) {
    std::cerr << "run through sudo, so the socket can belong to you" << std::endl;
    return 2;
  }

  pqrs::dispatcher::extra::initialize_shared_dispatcher();
  auto client = std::make_unique<pqrs::karabiner::driverkit::virtual_hid_device_service::client>();
  client->connected.connect([&client] {
    std::cout << "connected to the virtual HID daemon" << std::endl;
    pqrs::karabiner::driverkit::virtual_hid_device_service::virtual_hid_keyboard_parameters parameters(
        pqrs::hid::vendor_id::value_t(0x05ac), pqrs::hid::product_id::value_t(0x024f), pqrs::hid::country_code::us);
    client->async_virtual_hid_keyboard_initialize(parameters);
  });
  client->connect_failed.connect([](auto&& error) { std::cout << "connect_failed " << error << std::endl; });
  client->driver_version_mismatched.connect([](bool mismatched) {
    if (mismatched) std::cout << "driver version mismatched" << std::endl;
  });
  client->virtual_hid_keyboard_ready.connect([](bool value) {
    if (value != ready.exchange(value)) std::cout << "virtual keyboard ready: " << value << std::endl;
  });
  client->async_start();

  std::signal(SIGINT, [](int) { close(listener.exchange(-1)); });
  std::signal(SIGTERM, [](int) { close(listener.exchange(-1)); });

  std::string path = argv[1];
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (path.size() >= sizeof(address.sun_path)) {
    std::cerr << "socket path too long" << std::endl;
    return 2;
  }
  strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
  unlink(path.c_str());
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0 || bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
      chown(path.c_str(), static_cast<uid_t>(atoi(sudo_uid)), static_cast<gid_t>(atoi(sudo_gid))) != 0 ||
      chmod(path.c_str(), 0600) != 0 || listen(fd, 1) != 0) {
    perror("socket");
    return 1;
  }
  listener = fd;
  std::cout << "listening on " << path << std::endl;

  hid_report::keyboard_input report;
  auto post = [&] { client->async_post_report(report); };
  bool quit = false;
  while (!quit) {
    int connection = accept(listener.load(), nullptr, nullptr);
    if (connection < 0) break;
    FILE* stream = fdopen(connection, "r+");
    char buffer[256];
    while (fgets(buffer, sizeof(buffer), stream)) {
      std::string line(buffer);
      while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();
      std::string command = line.substr(0, line.find(' '));
      std::string key = line.find(' ') == std::string::npos ? "" : line.substr(line.find(' ') + 1);
      std::string reply = "ok";
      if (command == "ping") {
        reply = ready ? "ok" : "error keyboard not ready";
      } else if (command == "quit") {
        quit = true;
      } else if (command == "release") {
        report.modifiers.clear();
        report.keys.clear();
        post();
      } else if ((command == "down" || command == "up") && ready) {
        bool down = command == "down";
        if (auto modifier = modifier_named(key)) {
          down ? report.modifiers.insert(*modifier) : report.modifiers.erase(*modifier);
          post();
        } else if (auto usage = usage_named(key)) {
          down ? report.keys.insert(*usage) : report.keys.erase(*usage);
          post();
        } else {
          reply = "error unknown key " + key;
        }
      } else {
        reply = ready ? "error unknown command " + line : "error keyboard not ready";
      }
      fprintf(stream, "%s\n", reply.c_str());
      fflush(stream);
      if (quit) break;
    }
    fclose(stream);
  }

  // Leave no key held, then remove the keyboard.
  report.modifiers.clear();
  report.keys.clear();
  post();
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  client->async_virtual_hid_keyboard_terminate();
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  client = nullptr;
  pqrs::dispatcher::extra::terminate_shared_dispatcher();
  close(listener.exchange(-1));
  unlink(path.c_str());
  std::cout << "stopped" << std::endl;
  return 0;
}
