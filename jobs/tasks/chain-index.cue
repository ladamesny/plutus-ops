package tasks

import (
  "github.com/input-output-hk/plutus-ops/pkg/schemas/nomad:types"
)

#ChainIndexTask: #SimpleTask & {
  #stateVolume: string

  #memory: 2048

  let stateDir = "/var/lib/plutus-chain-index"

  #volumeMount: "index": types.#stanza.volume_mount & {
    volume: #stateVolume
    destination: stateDir
  }

  #extraEnv: {
    INDEX_STATE_DIR: stateDir
  }

}
