const { CrossbarClient } = require("@switchboard-xyz/common");
const fs = require("fs");

async function main() {
  try {
    // Read payload from stdin
    const payload = JSON.parse(fs.readFileSync(0, "utf8"));

    console.log("[NODE] Payload received:");
    console.log(payload);

    const crossbar = CrossbarClient.default();

    const result = await crossbar.resolveEVMRandomness({
      chainId: payload.chainId,
      randomnessId: payload.randomnessId,
      oracle: payload.oracle,
      timestamp: payload.timestamp,
      minStalenessSeconds: payload.minStalenessSeconds,
    });

    console.log("[NODE] Randomness resolved");

    // IMPORTANT: stdout must be pure JSON for Python
    process.stdout.write(
      JSON.stringify({
        encoded: result.encoded,
        previewValue: result.response.value.toString(),
      })
    );
  } catch (err) {
    console.error("[NODE ERROR]", err);
    process.exit(1);
  }
}

main();