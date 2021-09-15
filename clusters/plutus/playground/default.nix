{ self, lib, pkgs, config, ... }:
let
  inherit (pkgs.terralib) sops2kms sops2region cidrsOf;
  inherit (builtins) readFile replaceStrings;
  inherit (lib) mapAttrs' nameValuePair flip attrValues listToAttrs forEach;
  inherit (config) cluster;
  inherit (import ./security-group-rules.nix { inherit config pkgs lib; })
    securityGroupRules;

  bitte = self.inputs.bitte;

  amis = {
    us-east-2 = "ami-0492aa69cf46f79c3";
    eu-central-1 = "ami-0839f2c610f876d2d";
  };

in {
  imports = [ ./iam.nix ./secrets.nix ./vault-raft-storage.nix ];

  services.consul.policies.developer.servicePrefix."plutus-" = {
    policy = "write";
    intentions = "write";
  };

  services.nomad.policies = {
    admin.namespace."plutus-*".policy = "write";
    developer = {
      namespace."plutus-*".policy = "write";
      agent.policy = "read";
      quota.policy = "read";
      node.policy = "read";
      hostVolume."*".policy = "read";
    };
  };

  services.nomad.namespaces = { production.description = "Production"; };

  users.extraUsers.root.openssh.authorizedKeys.keys = pkgs.ssh-keys.devOps ++ [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID/fJqgjwPG7b5SRPtCovFmtjmAksUSNg3xHWyqBM4Cs shlevy@shlevy-laptop"
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCvmmnk1CO+alJANNP8UFn0TA0fwDVfiwT8zRpt5Y9qMLeRpvaBV7qpKHQuGB1dRLGpAq7Q1hyT2RzypueTkUBx6JxIFPxOsOfNgSoygTFamhWhlWbSbvvvmt9BVM29af6Ju5wLSZqvj0yFjrVi4mb0Rmu2cFbTXIHruwIFWRTmyJMCZEsaXW266ss0etNGiFW5KX3n9hqncjgYaAnQtG86XNASVM+tZcSHlci47SQB8LsKFC/olf2KOAVL/kM2KTIT1Rimm1N/gbixd5psICAYY7py7wFQO08dh7ylJJgNaAyT6FVFoIhk6ztSGxVH9wTA2wE2F1PlJM+1AgHDPWUISmNHkhEztwjiVPP80ysXDDuRfilQWI53piPtJTAyJu5mFDzVhfjFMJ2EEP7uBrVEA3SpoP931JF/98BhUNH/dW5tkFr0IY7ecAEP5qg5QXzvHKS2WDLwbDeQslq0QVkz1dogLTShfB2HzE/YLwfkkeM9oWHt/kr42Bacv7flVWnu9hnIrlDS01tOV+QD2HZH5MLd2s5RNrgJbA2kmbn9n3Tob+SKaTL5FMF8RrnKxc259P1HqRWybjkOUyp9nnjM5GFrz7i0jcue9t6Zj2+3TPEV3aEaZWfkZkaodcdKyBceW1xXpFQp7v5HKAXea0Z9R+vVrG1LNO3M8sq0gCfjNQ=="
  ];

  cluster = {
    name = "plutus-playground";

    adminNames = [ "michael.bishop" ];
    developerGithubNames = [ ];
    developerGithubTeamNames = [ "plutus" ];
    domain = "plutus.aws.iohkdev.io";
    kms =
      "arn:aws:kms:eu-central-1:048156180985:key/7aa3ec8c-168f-42b8-9f77-6f5d7a9002d0";
    s3Bucket = "plutus-ops";
    terraformOrganization = "production-plutus-playground";

    s3CachePubKey = lib.fileContents ../../../encrypted/nix-public-key-file;
    flakePath = ../../..;

    autoscalingGroups = listToAttrs (forEach [{
      region = "eu-central-1";
      desiredCapacity = 2;
    }
    #{
    #  region = "us-east-2";
    #  desiredCapacity = 8;
    #}
      ] (args:
        let
          attrs = ({
            desiredCapacity = 1;
            maxSize = 40;
            instanceType = "c5.2xlarge";
            associatePublicIP = true;
            maxInstanceLifetime = 0;
            iam.role = cluster.iam.roles.client;
            iam.instanceProfile.role = cluster.iam.roles.client;

            modules = [
              (bitte + /profiles/client.nix)
              ./marlowe-run.nix
              self.inputs.ops-lib.nixosModules.zfs-runtime
              "${self.inputs.nixpkgs}/nixos/modules/profiles/headless.nix"
              "${self.inputs.nixpkgs}/nixos/modules/virtualisation/ec2-data.nix"
            ];

            securityGroupRules = {
              inherit (securityGroupRules) internet internal ssh;
            };
            ami = amis.${args.region};
          } // args);
          asgName = "client-${attrs.region}-${
              replaceStrings [ "." ] [ "-" ] attrs.instanceType
            }";
        in nameValuePair asgName attrs));

    instances = {
      core-1 = {
        instanceType = "t3a.medium";
        privateIP = "172.16.0.10";
        subnet = cluster.vpc.subnets.core-1;

        modules =
          [ (bitte + /profiles/core.nix) (bitte + /profiles/bootstrapper.nix) ];

        securityGroupRules = {
          inherit (securityGroupRules)
            internet internal ssh http https haproxyStats vault-http grpc;
        };
      };

      core-2 = {
        instanceType = "t3a.medium";
        privateIP = "172.16.1.10";
        subnet = cluster.vpc.subnets.core-2;

        modules = [ (bitte + /profiles/core.nix) ];

        securityGroupRules = {
          inherit (securityGroupRules) internet internal ssh;
        };
      };

      core-3 = {
        instanceType = "t3a.medium";
        privateIP = "172.16.2.10";
        subnet = cluster.vpc.subnets.core-3;

        modules = [ (bitte + /profiles/core.nix) ];

        securityGroupRules = {
          inherit (securityGroupRules) internet internal ssh;
        };
      };

      monitoring = {
        instanceType = "t3a.large";
        privateIP = "172.16.0.20";
        subnet = cluster.vpc.subnets.core-1;
        volumeSize = 500;
        route53.domains = [
          "consul.${cluster.domain}"
          "docker.${cluster.domain}"
          "monitoring.${cluster.domain}"
          "nomad.${cluster.domain}"
          "vault.${cluster.domain}"
          "vbk.${cluster.domain}"
        ];

        modules = [ (bitte + /profiles/monitoring.nix) ];

        securityGroupRules = {
          inherit (securityGroupRules) internet internal ssh http https;
        };
      };

      routing = {
        instanceType = "t3a.small";
        privateIP = "172.16.1.40";
        subnet = cluster.vpc.subnets.core-2;
        volumeSize = 100;
        route53.domains = [ "*.${cluster.domain}" ];

        modules = [ (bitte + /profiles/routing.nix) ./traefik.nix ];

        securityGroupRules = {
          inherit (securityGroupRules) internet internal ssh http routing;
        };
      };
    };
  };
}
