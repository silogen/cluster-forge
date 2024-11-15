use std::{
	collections::HashMap,
	env,
	fs::{self, File, OpenOptions},
	io::{self, Write},
	path::Path,
	process::Command,
	error::Error,
    };
use log::{debug, info};
use serde::{Deserialize, Serialize};
use serde_yaml;
    
#[derive(Debug, Serialize)]
pub struct PlatformPackage {
    pub name: String,
    pub kind: String,
    pub content: String,
    pub index: usize,
    pub package_type: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct ConfigMap {
    api_version: String,
    kind: String,
    metadata: Metadata,
}

#[derive(Debug, Serialize, Deserialize)]
struct Metadata {
    name: String,
}

#[derive(Debug, Serialize)]
struct VolumeMount {
    mount_path: String,
    name: String,
    read_only: bool,
}

#[derive(Debug, Serialize)]
struct Volume {
    name: String,
    config_map: ConfigMapVolume,
}

#[derive(Debug, Serialize)]
struct ConfigMapVolume {
    name: String,
}

#[derive(Debug, Serialize)]
struct Container {
    name: String,
    volume_mounts: Vec<VolumeMount>,
}

#[derive(Debug, Serialize)]
struct PodSpec {
    containers: Vec<Container>,
    volumes: Vec<Volume>,
}

#[derive(Debug, Serialize)]
struct TemplateSpec {
    spec: PodSpec,
}

#[derive(Debug, Serialize)]
struct DeploymentTemplateSpec {
    selector: HashMap<String, String>,
    template: TemplateSpec,
}

#[derive(Debug, Serialize)]
struct DeploymentTemplate {
    spec: DeploymentTemplateSpec,
}

#[derive(Debug, Serialize)]
struct DeploymentRuntimeConfig {
    api_version: String,
    kind: String,
    metadata: Metadata,
    spec: DeploymentTemplate,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Config {
    pub helm_chart_name: Option<String>,
    pub helm_url: Option<String>,
    pub values: Option<String>,
    pub secrets: Option<bool>,
    pub name: String,
    pub helm_name: Option<String>,
    pub manifest_url: Option<String>,
    pub helm_version: Option<String>,
    pub namespace: Option<String>,
    pub source_file: Option<String>,
    pub filename: Option<String>,
    pub crd_files: Option<Vec<String>>,
    pub secret_files: Option<Vec<String>>,
    pub external_secret_files: Option<Vec<String>>,
    pub object_files: Option<Vec<String>>,
    pub cast_name: Option<Vec<String>>,
}



pub fn should_skip_file(file_path: &Path) -> bool {
    if file_path.is_dir() {
        return true;
    }
    let content = match fs::read_to_string(file_path) {
        Ok(c) => c,
        Err(_) => return true,
    };
    content.contains("helm.sh/hook")
}

pub fn create_crossplane_object(config: &Config) -> Result<(), Box<dyn Error>> {
    const MAX_FILE_SIZE: usize = 300 * 1024; // 300 KB

    let mut file_indices = HashMap::new();
    file_indices.insert("crd", 1);
    file_indices.insert("object", 1);
    file_indices.insert("secret", 1);
    file_indices.insert("externalsecret", 1);

    let working_dir = format!("working/{}", config.name);
    let output_dir = "output";

    fs::create_dir_all(output_dir)?;

    for entry in fs::read_dir(&working_dir)? {
        let entry = entry?;
        let file_path = entry.path();

        if should_skip_file(&file_path) {
            continue;
        }

        let file_name = file_path.file_name().unwrap().to_string_lossy();
        let file_type = if file_name.contains("crd") {
            "crd"
        } else if file_name.contains("externalsecret") {
            "externalsecret"
        } else if file_name.contains("secret") {
            "secret"
        } else {
            "object"
        };

        let index = file_indices.get_mut(file_type).unwrap();
        let output_file = format!("{}/{}-{}-{}.yaml", output_dir, file_type, config.name, index);

        let mut current_file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&output_file)?;

        let current_size = current_file.metadata()?.len() as usize;
        let content = fs::read_to_string(&file_path)?;

        if current_size + content.len() > MAX_FILE_SIZE {
            *index += 1;
        }

        writeln!(current_file, "{}", content)?;
    }

    Ok(())
}


pub fn generate_function_templates(output_dir: &str, new_file_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let mut deployment_runtime_config = DeploymentRuntimeConfig {
        api_version: "pkg.crossplane.io/v1beta1".to_string(),
        kind: "DeploymentRuntimeConfig".to_string(),
        metadata: Metadata {
            name: "mount-templates".to_string(),
        },
        spec: DeploymentTemplate {
            spec: DeploymentTemplateSpec {
                selector: HashMap::new(),
                template: TemplateSpec {
                    spec: PodSpec {
                        containers: vec![Container {
                            name: "package-runtime".to_string(),
                            volume_mounts: Vec::new(),
                        }],
                        volumes: Vec::new(),
                    },
                },
            },
        },
    };

    for entry in fs::read_dir(output_dir)? {
        let entry = entry?;
        let path = entry.path();

        if let Some(ext) = path.extension() {
            if ext == "yaml" {
                let content = fs::read_to_string(&path)?;
                let config_map: ConfigMap = serde_yaml::from_str(&content)?;

                if config_map.kind == "ConfigMap" {
                    let volume_mount = VolumeMount {
                        mount_path: format!("/templates/{}", config_map.metadata.name),
                        name: config_map.metadata.name.clone(),
                        read_only: true,
                    };
                    let volume = Volume {
                        name: config_map.metadata.name.clone(),
                        config_map: ConfigMapVolume {
                            name: config_map.metadata.name.clone(),
                        },
                    };

                    if let Some(container) = deployment_runtime_config.spec.spec.template.spec.containers.first_mut() {
                        container.volume_mounts.push(volume_mount);
                    }
                    deployment_runtime_config.spec.spec.template.spec.volumes.push(volume);
                }
            }
        }
    }

    let yaml_content = serde_yaml::to_string(&deployment_runtime_config)?;
    fs::write(new_file_path, yaml_content)?;
    info!("New volume structure written to {}", new_file_path);

    Ok(())
}

pub fn copy_yaml_files(src_dir: &str, dest_dir: &str) -> Result<(), Box<dyn std::error::Error>> {
    for entry in fs::read_dir(src_dir)? {
        let entry = entry?;
        let src_path = entry.path();

        if src_path.extension().and_then(|ext| ext.to_str()) == Some("yaml") {
            let dest_path = Path::new(dest_dir).join(src_path.file_name().unwrap());
            fs::copy(&src_path, &dest_path)?;
        }
    }

    Ok(())
}

pub fn remove_yaml_files(dir: &str) -> Result<(), Box<dyn std::error::Error>> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();

        if path.extension().and_then(|ext| ext.to_str()) == Some("yaml") {
            fs::remove_file(path)?;
        }
    }

    Ok(())
}

pub fn setup_logging() -> Result<(), Box<dyn std::error::Error>> {
    let log_level = env::var("LOG_LEVEL").unwrap_or_else(|_| "info".to_string());
    env_logger::Builder::new()
        .filter(None, log_level.parse()?)
        .init();
    
    let log_file = env::var("LOG_NAME").unwrap_or_else(|_| "app.log".to_string());
    let log_path = Path::new("logs").join(log_file);

    let _ = File::create(&log_path)?;

    Ok(())
}


pub fn load_config(path: &str) -> Result<Vec<Config>, Box<dyn Error>> {
    let data = fs::read_to_string(path)?;
    let configs: Vec<Config> = serde_yaml::from_str(&data)?;
    validate_config(&configs)?;
    Ok(configs)
}

pub fn validate_config(configs: &[Config]) -> Result<(), Box<dyn Error>> {
    for config in configs {
        if config.name.is_empty() {
            return Err(format!("Missing 'name' in config: {:?}", config).into());
        }
        if config.namespace.is_none() {
            return Err(format!("Missing 'namespace' in config: {:?}", config).into());
        }
        if config.manifest_url.is_none()
            && config.helm_url.is_none()
            && config.source_file.is_none()
        {
            return Err(format!(
                "Either 'manifest-url', 'helm-url', or 'source-file' must be provided in config: {:?}",
                config
            )
            .into());
        }
        if let Some(ref helm_url) = config.helm_url {
            if config.helm_chart_name.is_none() {
                return Err(format!("Missing 'helm-chart-name' in config with 'helm-url': {:?}", helm_url).into());
            }
            if config.helm_name.is_none() {
                return Err(format!("Missing 'helm-name' in config with 'helm-url': {:?}", helm_url).into());
            }
            if config.values.is_none() {
                return Err(format!("Missing 'values' in config with 'helm-url': {:?}", helm_url).into());
            }
        }
    }
    Ok(())
}

pub fn template_helm(config: &Config) -> Result<(), Box<dyn Error>> {
    let filename = config.filename.as_ref().unwrap();
    let mut file = File::create(filename)?;

    if let Some(ref helm_url) = config.helm_url {
        let mut cmd = Command::new("helm");
        cmd.arg("template")
            .arg(config.helm_name.as_ref().unwrap())
            .arg("--repo")
            .arg(helm_url)
            .arg(config.helm_chart_name.as_ref().unwrap());

        if let Some(ref version) = config.helm_version {
            cmd.arg("--version").arg(version);
        }

        if let Some(ref namespace) = config.namespace {
            cmd.arg("--namespace").arg(namespace);
        }

        if let Some(ref values) = config.values {
            cmd.arg("-f").arg(format!("input/{}/{}", config.name, values));
        }

        let output = cmd.output()?;

        if !output.status.success() {
            return Err(format!(
                "Helm command failed: {}",
                String::from_utf8_lossy(&output.stderr)
            )
            .into());
        }

        file.write_all(&output.stdout)?;
    } else if let Some(ref source_file) = config.source_file {
        debug!("Using source file: {}", source_file);
        let src_path = Path::new("input").join(source_file);
        let dest_path = Path::new("working/pre").join(source_file);
        fs::copy(src_path, dest_path)?;
    } else if let Some(ref manifest_url) = config.manifest_url {
        debug!("Fetching manifest URL: {}", manifest_url);
        let response = reqwest::blocking::get(manifest_url)?;
        let mut dest = File::create(filename)?;
        io::copy(&mut response.bytes()?.as_ref(), &mut dest)?;
    }

    Ok(())
}

pub fn remove_empty_yaml_files(dir: &Path) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.extension().map_or(false, |ext| ext == "yaml") {
            let metadata = fs::metadata(&path)?;
            if metadata.len() == 0 {
                fs::remove_file(&path)?;
            }
        }
    }
    Ok(())
}
