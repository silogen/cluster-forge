## Usage

The process of creating and deploying a stack involves 3 to 5 steps depending on your use case.

---

### Step 0: Configure Tools (Optional)

If a required tool or component is missing, add it to the `input/config.yaml` file.

---

### Step 1: Smelt

The `smelt` step normalizes YAML configurations for the selected components.

Run the following command:

```sh
go run . smelt
```

This will generate formatted YAML configs based on your selections.

![Smelt Demo](gifs/demoSmelt.gif)

---

### Step 2: Customize (Optional)

To tailor your configuration, edit files under the `/working` directory.  
While this step is optional for basic testing, it is essential to unlock the full benefits of Cluster-Forge. Detailed instructions will be provided in a future release.

![Customization Demo](gifs/demoCustomize.gif)

---

### Step 3: Cast

The `cast` step compiles the components into a deployable stack image. By default, an image is created and pushed to an [ephemeral registry](ttl.sh) where it will be available for 12 hours. 

To push the image instead to a registry of your choice, set env variable PUBLISH_IMAGE=true and you will be given the option to specify the registry, image name and tag. 

Run the following command:

```sh
go run . cast
```

Or, to run with a non-ephemeral registry, run the following command:

```sh
PUBLISH_IMAGE=true go run . cast
```


> **Important:**  
> If you encounter build errors during the `cast` process, you may need to enable **multi-architecture Docker builds** with the following command:
> ```sh
> docker buildx create --name multiarch-builder --use
> ```

![Cast Demo](gifs/demoCast.gif)

---

### Step 4: Temper

**(Work in Progress)**  

This step ensures critical resources are available in the target environment, including:

- A storage class  
- An external-secrets backend  
- S3-compatible bucket storage  

If any of these components are unavailable, Cluster-Forge will identify the gaps and allow you to make tradeoff decisions as needed. More instructions for this step will be added in future releases.

---

### Step 5: Forge

The `forge` step deploys the compiled stack to your Kubernetes cluster.

Run the following command:

```sh
go run . forge
```
